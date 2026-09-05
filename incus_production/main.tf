terraform {
  required_providers {
    incus = {
      source  = "lxc/incus"
      version = "~> 1.2.0"
    }
    guacamole = {
      source  = "techBeck03/guacamole"
      version = "~> 1.4.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2.0"
    }
  }
}

provider "incus" {
  generate_client_certificates = true
  accept_remote_certificate    = true

  remote {
    name    = "servidor-incus"
    address = "192.168.1.100:8443"
    token   = "eyJjbGllbnRfbmFtZSI6InRlcnJhZm9ybS1sYWIiLCJmaW5nZXJwcmludCI6ImUxMzM2ZDc0NWUxZDI0ZjE4OGVjMGFkYzg1NWQ1YzMwY2IzN2JjNjA5ZGJiYTZlZGI2YjllYWFiZGUzYzQ3OTEiLCJhZGRyZXNzZXMiOlsiMTcyLjMxLjY3LjczOjg0NDMiLCIxMC4yNDUuMTcwLjE6ODQ0MyIsIltmZDQyOjI4YTQ6OWUxMTpjMDljOjoxXTo4NDQzIl0sInNlY3JldCI6IjE0ODFlYWUxOWFmNzQ5ZWJmZDI3ZDdjYWQ0NDhkZTNhYTE3MjNmNjQ2MjcwOTNkMmMzZWU4ZTFhZjM3ZDAzM2QiLCJleHBpcmVzX2F0IjoiMDAwMS0wMS0wMVQwMDowMDowMFoifQ=="
  }
}

provider "guacamole" {
  disable_tls_verification = true
  url      = var.guacamole_url
  username = var.guacamole_username
  password = var.guacamole_password
}

# ==============================================================================
# Variables de Guacamole
# ==============================================================================
variable "guacamole_url" {
  type        = string
  description = "URL pública o privada de Apache Guacamole (vía Nginx Proxy Manager)"
  default     = "https://laboratorio-guacamole.com"
}

variable "guacamole_username" {
  type        = string
  description = "Nombre de usuario de Guacamole"
  default     = "guacadmin"
}

variable "guacamole_password" {
  type        = string
  description = "Contraseña del usuario de Guacamole"
  default     = "guacadmin"
  sensitive   = true
}

# ==============================================================================
# 1. Variables: Diccionario de 40 alumnos con sus puertos, redes y contraseñas
# ==============================================================================
locals {
  alumnos = {
    "juan" = {
      ssh_port      = 2001
      subnet        = "10.20.10.1/24"
      guac_password = "PasswordJuan2026!"
    }
    "maria" = {
      ssh_port      = 2002
      subnet        = "10.20.11.1/24"
      guac_password = "PasswordMaria2026!"
    }
    "pedro" = {
      ssh_port      = 2003
      subnet        = "10.20.12.1/24"
      guac_password = "PasswordPedro2026!"
    }
  }
}

# ==============================================================================
# 2. Perfiles Compartidos
# ==============================================================================
resource "incus_profile" "base_alumno" {
  name   = "base-alumno"
  remote = "servidor-incus"
  config = {
    "limits.memory" = "512MB"
    "limits.cpu"    = "1"
  }
}

resource "incus_profile" "cloud_ansible" {
  name   = "cloud-ansible"
  remote = "servidor-incus"
  config = {
    "user.user-data" = <<-EOF
      #cloud-config
      package_update: true
      packages:
        - openssh-server
      users:
        - name: ansible
          groups: [sudo, wheel]
          sudo: ALL=(ALL) NOPASSWD:ALL
          shell: /bin/bash
          lock_passwd: false
      chpasswd:
        list: |
          ansible:ansible
        expire: false
      runcmd:
        - which sshd || (apt-get update && apt-get install -y openssh-server) || (dnf install -y openssh-server) || true
        - sed -i 's/^#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null || true
        - sed -i 's/^PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null || true
        - systemctl enable --now ssh || systemctl enable --now sshd
        - systemctl restart ssh || systemctl restart sshd
        - chmod u+s /usr/bin/ping /bin/ping 2>/dev/null || true
        - echo "net.ipv4.ping_group_range = 0 65535" > /etc/sysctl.d/99-ping.conf && sysctl -p /etc/sysctl.d/99-ping.conf || true
        - for h in /home/* /root /etc/skel; do [ -d "$h" -a -f "$h/.bashrc" ] && sed -i 's/#force_color_prompt=yes/force_color_prompt=yes/g' "$h/.bashrc"; done
        - echo 'alias ls="ls --color=auto"' >> /etc/profile.d/color_prompt.sh || true
      power_state:
        mode: poweroff
        timeout: 5
        condition: True
    EOF
  }
}

# ==============================================================================
# 3. Redes Aisladas con resolución DNS interna para nodos
# ==============================================================================
resource "incus_network" "lab_net" {
  for_each = local.alumnos
  name     = length("lab-net-${each.key}") <= 15 ? "lab-net-${each.key}" : "net-${each.key}"
  remote   = "servidor-incus"

  config = {
    "ipv4.address" = each.value.subnet
    "ipv4.nat"     = "true"
    "ipv6.address" = "none"
    "raw.dnsmasq"  = <<-EOF
      cname=nodo-ubuntu.incus,nodo-ubuntu-${each.key}.incus
      cname=nodo-ubuntu,nodo-ubuntu-${each.key}.incus
      cname=nodo-rocky.incus,nodo-rocky-${each.key}.incus
      cname=nodo-rocky,nodo-rocky-${each.key}.incus
      cname=ansible-control.incus,ansible-control-${each.key}.incus
      cname=ansible-control,ansible-control-${each.key}.incus
    EOF
  }
}

# ==============================================================================
# 4. Nodos de Control (Ubuntu) con el proxy configurado
# ==============================================================================
resource "incus_instance" "ansible_control" {
  for_each = local.alumnos
  name     = "ansible-control-${each.key}"
  remote   = "servidor-incus"
  image    = "images:ubuntu/24.04/cloud"
  profiles = ["default", incus_profile.base_alumno.name, incus_profile.cloud_ansible.name]

  # Configuración de red
  device {
    name = "eth0"
    type = "nic"  
    properties = {
      network = incus_network.lab_net[each.key].name
    }
  }

  device {
    name = "proxy-ssh"
    type = "proxy"
    properties = {
      listen  = "tcp:0.0.0.0:${each.value.ssh_port}"
      connect = "tcp:127.0.0.1:22"
    }
  }
}

# ==============================================================================
# 5. Nodos de Pruebas 1 (Ubuntu)
# ==============================================================================
resource "incus_instance" "nodo_ubuntu" {
  for_each = local.alumnos
  name     = "nodo-ubuntu-${each.key}"
  remote   = "servidor-incus"
  image    = "images:ubuntu/24.04/cloud"
  profiles = ["default", incus_profile.base_alumno.name, incus_profile.cloud_ansible.name]

  device {
    name = "eth0"
    type = "nic"
    properties = {
      network = incus_network.lab_net[each.key].name
    }
  }
}

# ==============================================================================
# 6. Nodos de Pruebas 2 (Rocky)
# ==============================================================================
resource "incus_instance" "nodo_rocky" {
  for_each = local.alumnos
  name     = "nodo-rocky-${each.key}"
  remote   = "servidor-incus"
  image    = "images:rockylinux/9/cloud"
  profiles = ["default", incus_profile.base_alumno.name, incus_profile.cloud_ansible.name]

  device {
    name = "eth0"
    type = "nic"
    properties = {
      network = incus_network.lab_net[each.key].name
    }
  }
}

# ==============================================================================
# 7. Conexiones SSH en Apache Guacamole hacia los Contenedores Incus
# ==============================================================================
resource "guacamole_connection_ssh" "alumno_ssh" {
  for_each          = local.alumnos
  name              = "Terminal-Ansible-${each.key}"
  parent_identifier = "ROOT"

  parameters {
    # IP privada del host Incus (comunicación interna)
    hostname = "172.31.67.73"
    port     = each.value.ssh_port
    username = "ansible"
    password = "ansible"
    # NOTA: color_scheme, font_name y font_size se aplican vía SQL
    # porque el provider de Terraform solo acepta valores predefinidos.
  }

  lifecycle {
    ignore_changes = [attributes, parameters]
  }

  depends_on = [incus_instance.ansible_control]
}

# ==============================================================================
# 8. Usuarios en Apache Guacamole con acceso a su respectivo equipo
# ==============================================================================
resource "guacamole_user" "alumno" {
  for_each = local.alumnos

  username    = each.key
  password    = each.value.guac_password
  connections = [guacamole_connection_ssh.alumno_ssh[each.key].identifier]

  lifecycle {
    ignore_changes = [password]
  }
}

# ==============================================================================
# 9. Aplicar paleta Nord y fuente Caskaydia a TODAS las conexiones SSH
#    (El provider de Terraform no soporta color_scheme personalizado,
#     así que se inyecta directamente en PostgreSQL tras cada apply)
# ==============================================================================
resource "null_resource" "apply_terminal_theme" {
  # Se re-ejecuta cada vez que se crea una nueva conexión SSH
  triggers = {
    connection_ids = join(",", [for k, v in guacamole_connection_ssh.alumno_ssh : v.identifier])
  }

  provisioner "local-exec" {
    command = <<-EOT
      ssh -i ./laboratorio-ansible.pem -o StrictHostKeyChecking=no ubuntu@ec2-3-12-169-63.us-east-2.compute.amazonaws.com "
        sudo docker exec guacamole-db psql -U guacamole_user -d guacamole_db -c \"
          INSERT INTO guacamole_connection_parameter (connection_id, parameter_name, parameter_value)
          SELECT connection_id, 'color-scheme', 'background: rgb:2E/34/40; foreground: rgb:D8/DE/E9; color0: rgb:3B/42/52; color1: rgb:BF/61/6A; color2: rgb:A3/BE/8C; color3: rgb:EB/CB/8B; color4: rgb:81/A1/C1; color5: rgb:B4/8E/AD; color6: rgb:88/C0/D0; color7: rgb:E5/E9/F0; color8: rgb:4C/56/6A; color9: rgb:BF/61/6A; color10: rgb:A3/BE/8C; color11: rgb:EB/CB/8B; color12: rgb:81/A1/C1; color13: rgb:B4/8E/AD; color14: rgb:8F/BC/BB; color15: rgb:EC/EF/F4;'
          FROM guacamole_connection
          WHERE connection_id NOT IN (SELECT connection_id FROM guacamole_connection_parameter WHERE parameter_name = 'color-scheme');

          INSERT INTO guacamole_connection_parameter (connection_id, parameter_name, parameter_value)
          SELECT connection_id, 'font-name', 'Caskaydia Cove Nerd Font, Cascadia Code, Consolas, monospace'
          FROM guacamole_connection
          WHERE connection_id NOT IN (SELECT connection_id FROM guacamole_connection_parameter WHERE parameter_name = 'font-name');

          INSERT INTO guacamole_connection_parameter (connection_id, parameter_name, parameter_value)
          SELECT connection_id, 'font-size', '12'
          FROM guacamole_connection
          WHERE connection_id NOT IN (SELECT connection_id FROM guacamole_connection_parameter WHERE parameter_name = 'font-size');
        \"
      "
    EOT
  }

  depends_on = [guacamole_connection_ssh.alumno_ssh]
}
