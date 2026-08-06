locals {
  common_tags = merge(
    {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "terraform"
    },
    var.extra_tags
  )

  name = "${var.project_name}-${var.environment}"
}

# Usamos la VPC y subnet default de la cuenta/región — para una sola
# instancia no hace falta una VPC dedicada. Si más adelante hace falta
# aislar la red (ej. una segunda instancia para staging), reemplazar estos
# data sources por un módulo de VPC propio.
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }

  filter {
    name   = "default-for-az"
    values = ["true"]
  }
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_key_pair" "this" {
  key_name   = "${local.name}-key"
  public_key = file(var.ssh_public_key_path)
  tags       = local.common_tags
}

resource "aws_instance" "app" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  subnet_id              = data.aws_subnets.default.ids[0]
  key_name               = aws_key_pair.this.key_name
  vpc_security_group_ids = [aws_security_group.app.id]
  iam_instance_profile   = aws_iam_instance_profile.app.name

  root_block_device {
    volume_type = "gp3"
    volume_size = var.root_volume_size_gb
    encrypted   = true
  }

  # Bootstrap mínimo — el resto (Docker, runner, cloudflared, Postgres) lo
  # hace Ansible, no Terraform, para que la configuración sea idempotente y
  # re-ejecutable sin recrear la instancia. Esto solo deja la máquina lista
  # para que Ansible se pueda conectar.
  user_data = <<-EOF
    #!/bin/bash
    set -euxo pipefail
    apt-get update -y
    apt-get install -y python3 python3-apt
  EOF

  metadata_options {
    http_tokens = "required" # IMDSv2 obligatorio
  }

  tags = merge(local.common_tags, { Name = local.name })

  lifecycle {
    # user_data solo corre una vez al crear la instancia — un cambio ahí no
    # debería forzar destruir/recrear la máquina (perderíamos el runner
    # registrado, los túneles, y el volumen de Postgres si no está en un
    # volumen separado).
    ignore_changes = [user_data, ami]
  }
}

resource "aws_eip" "app" {
  instance = aws_instance.app.id
  domain   = "vpc"
  tags     = merge(local.common_tags, { Name = "${local.name}-eip" })
}
