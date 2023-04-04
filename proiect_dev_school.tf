terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.0"
    }
  }
}

# Configure the AWS Provider
provider "aws" {
  region = "us-east-1"
}

resource "aws_security_group" "allow_http_ssh" {
  name_prefix = "allow_http_ssh"
  description = "Security group that permits traffic on ports 80 and 22 from any ip"
  vpc_id      = "vpc-097b9561beedc0243"

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_lb" "load-balancer" {
  name               = "load-balancer"
  internal           = false
  load_balancer_type = "application"
  subnets            = ["subnet-03ebc6b24b65f70d7", "subnet-043a3ddea458bd3d8"]
  security_groups    = [aws_security_group.allow_http_ssh.id]
  
}

resource "aws_launch_configuration" "ec2_configuration" {
  name_prefix                 = "ec2_configuration"
  image_id                    = "ami-00c39f71452c08778"
  instance_type               = "t2.micro"
  security_groups             = [aws_security_group.allow_http_ssh.id]
  key_name                    = "demo"
  associate_public_ip_address = true
  user_data = <<-EOF
    #!/bin/bash
    sudo yum update -y
    sudo yum install docker -y
    sudo usermod -a -G docker ec2-user
    id ec2-user
    newgrp docker
    sudo systemctl start docker
    sudo systemctl enable docker
    docker network create -d bridge devopslabs
    docker run -d -p 4000:4000 --name dotnet_backend_application --network devopslabs tibialex2000/dotnet_backend_application:d2e9394
    sudo mkdir /frontend
    sudo mkdir /nginxconf
    sudo touch /frontend/index.html
    sudo chmod a+w frontend/
    sudo touch /nginxconf/default.conf
    sudo chmod a+w /nginxconf
    sudo echo "server {
      listen       80;
      listen  [::]:80;
      server_name  localhost;

      location / {
          root   /usr/share/nginx/html;
          try_files \$uri \$uri/  /index.html;
      }

      location /api {
          proxy_pass http://dotnet_backend_application:4000;
      }

      error_page   500 502 503 504  /50x.html;
      location = /50x.html {
          root   /usr/share/nginx/html;
      }
    }" | sudo tee /nginxconf/default.conf > /dev/null
    docker run -p 80:80 --name nginx -v $(pwd)/frontend:/usr/share/nginx/html:ro -v $(pwd)/nginxconf:/etc/nginx/conf.d:ro --network devopslabs -d nginx
    EOF
}

resource "aws_autoscaling_group" "group_of_instances" {
  name                      = "group_of_instances"
  depends_on                = [aws_lb_target_group.register-instances-to-lb]
  desired_capacity          = 2
  max_size                  = 3
  min_size                  = 1
  health_check_grace_period = 300
  health_check_type         = "ELB"
  launch_configuration      = aws_launch_configuration.ec2_configuration.id
  vpc_zone_identifier       = ["subnet-03ebc6b24b65f70d7", "subnet-043a3ddea458bd3d8"]
  target_group_arns         = [aws_lb_target_group.register-instances-to-lb.arn]
}

resource "aws_autoscaling_policy" "request_policy_up" {
    name                    = "request-policy-up"
    autoscaling_group_name  = aws_autoscaling_group.group_of_instances.name
    policy_type             = "SimpleScaling"
    scaling_adjustment      = 1
    cooldown                = 300
    adjustment_type         = "ChangeInCapacity"
}

resource "aws_autoscaling_policy" "request_policy_down" {
    name                    = "request-policy-down"
    autoscaling_group_name  = aws_autoscaling_group.group_of_instances.name
    policy_type             = "SimpleScaling"
    scaling_adjustment      = -1
    cooldown                = 300
    adjustment_type         = "ChangeInCapacity"
}

resource "aws_cloudwatch_metric_alarm" "request_alarm_up" {
  alarm_name          = "request_alarm_up"
  alarm_description   = "alarm that scales up if cpu is above treshhold"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 2
  metric_name         = "RequestCount"
  namespace           = "AWS/ApplicationELB"
  period              = 120
  statistic           = "Sum"
  threshold           = 10
  unit                = "Count"
  dimensions    = {
    LoadBalancer = split("loadbalancer/", split(":", aws_lb.load-balancer.arn)[5])[1]
  }
  actions_enabled = true
  alarm_actions   = [aws_autoscaling_policy.request_policy_up.arn]
}

resource "aws_cloudwatch_metric_alarm" "request_alarm_down" {
  alarm_name          = "request_alarm_down"
  alarm_description   = "alarm that scales down if cpu is above treshhold"
  comparison_operator = "LessThanOrEqualToThreshold"
  evaluation_periods  = 2
  metric_name         = "RequestCount"
  namespace           = "AWS/ApplicationELB"
  period              = 120
  statistic           = "Sum"
  threshold           = 3
  unit                = "Count"
  dimensions = {
    LoadBalancer = split("loadbalancer/", split(":", aws_lb.load-balancer.arn)[5])[1]
  }
  actions_enabled = true
  alarm_actions = [aws_autoscaling_policy.request_policy_down.arn]
}

resource "aws_lb_target_group" "register-instances-to-lb" {
  name     = "register-instances-to-lb"
  port     = 80
  protocol = "HTTP"
  vpc_id   = "vpc-097b9561beedc0243"
  target_type = "instance"

  health_check {
    path     = "/"
    interval = 25
    timeout  = 5
    healthy_threshold = 2
    unhealthy_threshold = 5
  }
}

resource "aws_autoscaling_attachment" "attachment" {
  autoscaling_group_name = aws_autoscaling_group.group_of_instances.id
  lb_target_group_arn    = aws_lb_target_group.register-instances-to-lb.arn
}

resource "aws_lb_listener" "CF2TF-ALB-Listener" {
  load_balancer_arn = aws_lb.load-balancer.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    target_group_arn = aws_lb_target_group.register-instances-to-lb.arn
    type             = "forward"
  }
}