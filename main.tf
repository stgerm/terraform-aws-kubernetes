#####
# AWS Prodvider
#####

# Retrieve AWS credentials from env variables AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY
provider "aws" {
  region = "${var.aws_region}"
}

#####
# Generate kubeadm token
#####

module "kubeadm-token" {
  source = "scholzj/kubeadm-token/random"
}

#####
# IAM roles
#####

# Master

data "template_file" "master_policy_json" {
  template = "${file("${path.module}/template/master-policy.json.tpl")}"

  vars {}
}

resource "aws_iam_policy" "master_policy" {
  name        = "${var.cluster_name}-master"
  path        = "/"
  description = "Policy for role ${var.cluster_name}-master"
  policy      = "${data.template_file.master_policy_json.rendered}"
}

resource "aws_iam_role" "master_role" {
  name = "${var.cluster_name}-master"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Effect": "Allow",
      "Sid": ""
    }
  ]
}
EOF
}

resource "aws_iam_policy_attachment" "master-attach" {
  name       = "master-attachment"
  roles      = ["${aws_iam_role.master_role.name}"]
  policy_arn = "${aws_iam_policy.master_policy.arn}"
}

resource "aws_iam_instance_profile" "master_profile" {
  name  = "${var.cluster_name}-master"
  role = "${aws_iam_role.master_role.name}"
}

# Node

data "template_file" "node_policy_json" {
  template = "${file("${path.module}/template/node-policy.json.tpl")}"

  vars {}
}

resource "aws_iam_policy" "node_policy" {
  name        = "${var.cluster_name}-node"
  path        = "/"
  description = "Policy for role ${var.cluster_name}-node"
  policy      = "${data.template_file.node_policy_json.rendered}"
}

resource "aws_iam_role" "node_role" {
  name = "${var.cluster_name}-node"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Effect": "Allow",
      "Sid": ""
    }
  ]
}
EOF
}

resource "aws_iam_policy_attachment" "node-attach" {
  name       = "node-attachment"
  roles      = ["${aws_iam_role.node_role.name}"]
  policy_arn = "${aws_iam_policy.node_policy.arn}"
}

resource "aws_iam_instance_profile" "node_profile" {
  name  = "${var.cluster_name}-node"
  role = "${aws_iam_role.node_role.name}"
}

#####
# Security Group
#####

# Find VPC details based on Master subnet
data "aws_subnet" "cluster_subnet" {
  id = "${var.master_subnet_id}"
}

resource "aws_security_group" "kubernetes" {
  vpc_id = "${data.aws_subnet.cluster_subnet.vpc_id}"
  name = "${var.cluster_name}"

  tags = "${merge(map("Name", var.cluster_name, format("kubernetes.io/cluster/%v", var.cluster_name), "owned"), var.tags)}"
}

# Allow outgoing connectivity
resource "aws_security_group_rule" "allow_all_outbound_from_kubernetes" {
    type = "egress"
    from_port = 0
    to_port = 0
    protocol = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    security_group_id = "${aws_security_group.kubernetes.id}"
}

# Allow SSH connections only from specific CIDR (TODO)
resource "aws_security_group_rule" "allow_ssh_from_cidr" {
    count = "${length(var.ssh_access_cidr)}"
    type = "ingress"
    from_port = 22
    to_port = 22
    protocol = "tcp"
    cidr_blocks = ["${var.ssh_access_cidr[count.index]}"]
    security_group_id = "${aws_security_group.kubernetes.id}"
}

# Allow the security group members to talk with each other without restrictions
resource "aws_security_group_rule" "allow_cluster_crosstalk" {
    type = "ingress"
    from_port = 0
    to_port = 0
    protocol = "-1"
    source_security_group_id = "${aws_security_group.kubernetes.id}"
    security_group_id = "${aws_security_group.kubernetes.id}"
}

# Allow API connections only from specific CIDR (TODO)
resource "aws_security_group_rule" "allow_api_from_cidr" {
    count = "${length(var.api_access_cidr)}"
    type = "ingress"
    from_port = 6443
    to_port = 6443
    protocol = "tcp"
    cidr_blocks = ["${var.api_access_cidr[count.index]}"]
    security_group_id = "${aws_security_group.kubernetes.id}"
}

##########
# Keypair
##########

resource "aws_key_pair" "keypair" {
  key_name = "${var.cluster_name}"
  public_key = "${file(var.ssh_public_key)}"
}

#####
# AMI image
#####

data "aws_ami_ids" "centos7" {
  owners = ["aws-marketplace"]

  filter {
    name   = "product-code"
    values = ["aw0evgkw8e5c1q413zgy5pjce"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

#####
# Master - EC2 instance
#####

resource "aws_eip" "master" {
  vpc      = true
}

resource "aws_instance" "master" {
    instance_type = "${var.master_instance_type}"

    ami = "${data.aws_ami_ids.centos7.ids[0]}"

    key_name = "${aws_key_pair.keypair.key_name}"

    subnet_id = "${var.master_subnet_id}"

    associate_public_ip_address = false

    vpc_security_group_ids = [
        "${aws_security_group.kubernetes.id}"
    ]

    iam_instance_profile = "${aws_iam_instance_profile.master_profile.name}"

    user_data = <<EOF
#!/bin/bash
export KUBEADM_TOKEN=${module.kubeadm-token.token}
export DNS_NAME=${var.cluster_name}.${var.hosted_zone}
export CLUSTER_NAME=${var.cluster_name}
export ASG_NAME=${var.cluster_name}-nodes
export ASG_MIN_NODES="${var.min_worker_count}"
export ASG_MAX_NODES="${var.max_worker_count}"
export AWS_REGION=${var.aws_region}
export AWS_SUBNETS="${join(" ", var.worker_subnet_ids)}"
export ADDONS="${join(" ", var.addons)}"

curl 	https://s3.amazonaws.com/scholzj-kubernetes/cluster/init-aws-kubernetes-master.sh | bash
EOF

    tags = "${merge(map("Name", join("-", list(var.cluster_name, "master")), format("kubernetes.io/cluster/%v", var.cluster_name), "owned"), var.tags)}"

    root_block_device {
        volume_type = "gp2"
	      volume_size = "50"
	      delete_on_termination = true
    }

    depends_on = ["data.template_file.kubeadm_token"]

    lifecycle {
      ignore_changes = [
        "ami",
        "user_data",
        "associate_public_ip_address"
      ]
    }
}

resource "aws_eip_association" "master_assoc" {
  instance_id   = "${aws_instance.master.id}"
  allocation_id = "${aws_eip.master.id}"
}

#####
# Nodes
#####

resource "aws_launch_configuration" "nodes" {
  name          = "${var.cluster_name}-nodes"
  image_id      = "${data.aws_ami_ids.centos7.ids[0]}"
  instance_type = "${var.worker_instance_type}"
  key_name = "${aws_key_pair.keypair.key_name}"
  iam_instance_profile = "${aws_iam_instance_profile.node_profile.name}"

  security_groups = [
      "${aws_security_group.kubernetes.id}"
  ]

  associate_public_ip_address = true

  user_data = <<EOF
#!/bin/bash
export KUBEADM_TOKEN=${module.kubeadm-token.token}
export DNS_NAME=${var.cluster_name}.${var.hosted_zone}
export CLUSTER_NAME=${var.cluster_name}
export ADDONS="${join(" ", var.addons)}"

curl 	https://s3.amazonaws.com/scholzj-kubernetes/cluster/init-aws-kubernetes-node.sh | bash
EOF

  root_block_device {
      volume_type = "gp2"
	    volume_size = "50"
	    delete_on_termination = true
  }

  lifecycle {
    create_before_destroy = true
    ignore_changes = [
        "user_data"
    ]
  }
}

resource "aws_autoscaling_group" "nodes" {
  vpc_zone_identifier = "${var.worker_subnet_ids}"
  
  name                      = "${var.cluster_name}-nodes"
  max_size                  = "${var.max_worker_count}"
  min_size                  = "${var.min_worker_count}"
  desired_capacity          = "${var.min_worker_count}"
  launch_configuration      = "${aws_launch_configuration.nodes.name}"

  tags = [{
    key = "Name"
    value = "${var.cluster_name}-node"
    propagate_at_launch = true
  }]

  tags = [{
    key = "kubernetes.io/cluster/${var.cluster_name}"
    value = "owned"
    propagate_at_launch = true
  }]

  tags = ["${var.tags2}"]
}

#####
# DNS record
#####

data "aws_route53_zone" "dns_zone" {
  name         = "${var.hosted_zone}."
  private_zone = "${var.hosted_zone_private}"
}

resource "aws_route53_record" "master" {
  zone_id = "${data.aws_route53_zone.dns_zone.zone_id}"
  name    = "${var.cluster_name}.${var.hosted_zone}"
  type    = "A"
  records = ["${aws_eip.master.public_ip}"]
  ttl     = 300
}