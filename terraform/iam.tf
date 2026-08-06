data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "app" {
  name               = "${local.name}-app-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json
  tags               = local.common_tags
}

# Mínimo indispensable: el backend solo hace PutObject (ver
# server/src/routes/uploads.js) — nunca lee, lista ni borra del bucket, así
# que el rol no necesita esos permisos. Con esto en su lugar, AWS_ACCESS_KEY_ID
# / AWS_SECRET_ACCESS_KEY dejan de hacer falta en el .env del backend: el SDK
# de AWS toma las credenciales del rol de la instancia automáticamente.
data "aws_iam_policy_document" "s3_uploads" {
  statement {
    sid       = "PutUploads"
    actions   = ["s3:PutObject"]
    resources = ["arn:aws:s3:::${var.s3_bucket_name}/uploads/*"]
  }
}

resource "aws_iam_policy" "s3_uploads" {
  name   = "${local.name}-s3-uploads"
  policy = data.aws_iam_policy_document.s3_uploads.json
}

resource "aws_iam_role_policy_attachment" "s3_uploads" {
  role       = aws_iam_role.app.name
  policy_arn = aws_iam_policy.s3_uploads.arn
}

# Acceso de administración vía AWS Systems Manager Session Manager, como
# alternativa/respaldo a SSH — no hace falta abrir ningún puerto ni
# gestionar claves para entrar a la instancia desde la consola de AWS o la
# CLI (`aws ssm start-session --target <instance-id>`).
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.app.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "app" {
  name = "${local.name}-app-profile"
  role = aws_iam_role.app.name
  tags = local.common_tags
}
