# Identidad para que terraform-plan.yml / terraform-apply.yml (GitHub
# Actions) puedan tocar esta cuenta de AWS SIN una access key de larga vida
# guardada como secret — la cuenta es compartida con un montón de otros
# proyectos/clientes (EKS de Amaru, Canales, Kamui, etc.), así que una
# access key estática acá sería un riesgo innecesario. En cambio, GitHub
# emite un token OIDC de corta duración por cada corrida del workflow, y
# ese token se cambia por credenciales temporales vía este rol — nunca hay
# un secreto de AWS permanente que rotar ni que se pueda filtrar.

data "aws_caller_identity" "current" {}

resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  # Huella SHA1 del certificado raíz (y, como respaldo, el intermedio) que
  # devuelve hoy token.actions.githubusercontent.com — se sacó en vivo con:
  #   echo | openssl s_client -servername token.actions.githubusercontent.com \
  #     -connect token.actions.githubusercontent.com:443 -showcerts 2>/dev/null \
  #     | openssl x509 -fingerprint -sha1 -noout
  # (repetir por cada certificado del chain que muestre -showcerts). Si
  # GitHub rota la CA que usa (Let's Encrypt hoy) y `terraform plan` empieza
  # a fallar la conexión, hay que volver a sacarlo así y actualizar la lista.
  thumbprint_list = ["ab9d0263244dd0326eb67015705a667e79cfe998", "2d74d6dfd96eea55ad7baafa0d3c6552b2dadc37"]

  tags = local.common_tags
}

data "aws_iam_policy_document" "github_actions_assume_role" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Restringido a ESTE repo — cualquier otro repo de la cuenta/org de
    # GitHub del dueño del token no puede asumir este rol.
    #
    # El claim `sub` real (confirmado vía CloudTrail después de un primer
    # intento fallido) NO es el clásico "repo:owner/repo:..." — GitHub
    # inserta el ID numérico interno de la organización y del repo:
    #   repo:sitio-web-digital@309242884/infraestructura-sitio-web-digital-@1325860676:environment:production
    # (esto es a propósito de GitHub: así el trust policy no se rompe si
    # algún día se renombra la org o el repo). El `*` extra después de cada
    # segmento cubre ese "@<id>".
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${replace(var.github_repo, "/", "*/")}*:*"]
    }
  }
}

resource "aws_iam_role" "github_actions" {
  name               = "${local.name}-github-actions"
  assume_role_policy = data.aws_iam_policy_document.github_actions_assume_role.json
  tags               = local.common_tags
}

# Alcance: todo lo que terraform/*.tf necesita para plan/apply, pero nada
# fuera de los recursos de este proyecto — ni EKS, ni las otras cuentas/
# buckets que viven en la misma cuenta de AWS.
data "aws_iam_policy_document" "github_actions" {
  # EC2: describe es de solo lectura y no tiene forma de acotarlo por tag
  # (hace falta para que `terraform plan` pueda leer el estado real).
  # Las acciones que modifican algo si están acotadas: crear queda atado a
  # pedir el tag Project=sitiowebdigital en el recurso nuevo, y actuar sobre
  # un recurso YA creado queda atado a que ya tenga ese mismo tag.
  statement {
    sid       = "Ec2ReadOnly"
    actions   = ["ec2:Describe*"]
    resources = ["*"]
  }

  statement {
    sid = "Ec2CreateTaggedOnly"
    actions = [
      "ec2:RunInstances",
      "ec2:CreateTags",
      "ec2:AllocateAddress",
      "ec2:CreateSecurityGroup",
    ]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/Project"
      values   = [var.project_name]
    }
  }

  statement {
    sid = "Ec2ManageExistingTaggedOnly"
    actions = [
      "ec2:TerminateInstances",
      "ec2:StopInstances",
      "ec2:StartInstances",
      "ec2:ModifyInstanceAttribute",
      "ec2:ReleaseAddress",
      "ec2:AssociateAddress",
      "ec2:DisassociateAddress",
      "ec2:DeleteSecurityGroup",
      "ec2:AuthorizeSecurityGroupIngress",
      "ec2:AuthorizeSecurityGroupEgress",
      "ec2:RevokeSecurityGroupIngress",
      "ec2:RevokeSecurityGroupEgress",
    ]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Project"
      values   = [var.project_name]
    }
  }

  # Key pair: solo lectura — lo crea a mano `aws ec2 create-key-pair` (ver
  # README.md "Acceso SSH"), CI nunca lo crea ni lo borra.
  statement {
    sid       = "Ec2KeyPairReadOnly"
    actions   = ["ec2:DescribeKeyPairs"]
    resources = ["*"]
  }

  # IAM: solo el rol/política/instance-profile de ESTE proyecto (nombre
  # con el prefijo local.name), más el propio rol de GitHub Actions (para
  # que un `terraform plan` que lo toque no se rompa por falta de permiso).
  statement {
    sid = "IamManageProjectRoles"
    actions = [
      "iam:GetRole",
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:GetPolicy",
      "iam:GetPolicyVersion",
      "iam:CreatePolicy",
      "iam:CreatePolicyVersion",
      "iam:DeletePolicy",
      "iam:DeletePolicyVersion",
      "iam:ListPolicyVersions",
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
      "iam:ListAttachedRolePolicies",
      "iam:ListRolePolicies", # el provider de AWS la pide para detectar drift de políticas INLINE (ver aws_iam_role_policy.github_actions)
      "iam:ListInstanceProfilesForRole",
      "iam:GetInstanceProfile",
      "iam:CreateInstanceProfile",
      "iam:DeleteInstanceProfile",
      "iam:AddRoleToInstanceProfile",
      "iam:RemoveRoleFromInstanceProfile",
      "iam:TagInstanceProfile",
      "iam:PassRole",
    ]
    resources = [
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${local.name}-*",
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:policy/${local.name}-*",
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:instance-profile/${local.name}-*",
    ]
  }

  # El rol de OIDC en sí — para que terraform plan/apply pueda seguir
  # administrando este mismo archivo (ci.tf) sin quedar afuera.
  statement {
    sid = "IamManageOwnOidcRole"
    actions = [
      "iam:GetOpenIDConnectProvider",
      "iam:CreateOpenIDConnectProvider",
      "iam:UpdateOpenIDConnectProviderThumbprint",
      "iam:TagOpenIDConnectProvider",
      "iam:GetRolePolicy",
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
    ]
    resources = [
      aws_iam_openid_connect_provider.github.arn,
      aws_iam_role.github_actions.arn,
    ]
  }

  # Estado remoto de Terraform (el bucket lo crea terraform/bootstrap/, no
  # este rol). DeleteObject hace falta para soltar el lock nativo de S3
  # (use_lockfile crea un objeto "*.tflock" y lo borra al terminar) — sin
  # este permiso, un apply que sí termina bien igual falla al final
  # intentando liberar el lock, y lo deja trabado para la próxima corrida.
  statement {
    sid       = "TerraformStateBucket"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
    resources = ["arn:aws:s3:::${var.tfstate_bucket_name}", "arn:aws:s3:::${var.tfstate_bucket_name}/*"]
  }
}

resource "aws_iam_role_policy" "github_actions" {
  name   = "${local.name}-github-actions"
  role   = aws_iam_role.github_actions.id
  policy = data.aws_iam_policy_document.github_actions.json
}

output "github_actions_role_arn" {
  description = "ARN a pegar en el secret AWS_ROLE_ARN del repo de GitHub."
  value       = aws_iam_role.github_actions.arn
}
