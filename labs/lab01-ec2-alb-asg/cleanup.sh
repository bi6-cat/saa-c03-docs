#!/usr/bin/env bash
# Cleanup Lab 01 – xoá ASG, ALB, TG, LT, SG, IAM role
source "$(dirname "$0")/../_common.sh"
preflight
P=saa-lab01
confirm "$P-*"

echo "- Xoá Auto Scaling group (kéo theo terminate instance)..."
aws autoscaling delete-auto-scaling-group --auto-scaling-group-name $P-asg --force-delete 2>/dev/null
for _ in $(seq 1 30); do
  n=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names $P-asg --query 'length(AutoScalingGroups)' --output text 2>/dev/null)
  [ "${n:-0}" = "0" ] && break
  sleep 10
done

echo "- Xoá ALB (listener đi kèm)..."
ALB_ARN=$(awsq elbv2 describe-load-balancers --names $P-alb --query 'LoadBalancers[0].LoadBalancerArn')
if [ -n "$ALB_ARN" ]; then
  aws elbv2 delete-load-balancer --load-balancer-arn "$ALB_ARN"
  aws elbv2 wait load-balancers-deleted --load-balancer-arns "$ALB_ARN" 2>/dev/null
fi

echo "- Xoá target group..."
TG_ARN=$(awsq elbv2 describe-target-groups --names $P-tg --query 'TargetGroups[0].TargetGroupArn')
[ -n "$TG_ARN" ] && retry 12 aws elbv2 delete-target-group --target-group-arn "$TG_ARN"

echo "- Xoá launch template..."
aws ec2 delete-launch-template --launch-template-name $P-lt >/dev/null 2>&1

echo "- Xoá security groups (chờ ENI của ALB/EC2 được giải phóng)..."
for sg in $P-web-sg $P-alb-sg; do
  id=$(awsq ec2 describe-security-groups --filters "Name=group-name,Values=$sg" --query "SecurityGroups[0].GroupId")
  [ -n "$id" ] && { retry 18 aws ec2 delete-security-group --group-id "$id" && echo "  đã xoá $sg" || echo "  CHƯA xoá được $sg – thử lại sau vài phút"; }
done

echo "- Xoá IAM role + instance profile..."
ROLE=$P-ec2-role
for ip in $(awsq iam list-instance-profiles-for-role --role-name $ROLE --query "InstanceProfiles[].InstanceProfileName"); do
  aws iam remove-role-from-instance-profile --instance-profile-name "$ip" --role-name $ROLE
  aws iam delete-instance-profile --instance-profile-name "$ip"
done
for arn in $(awsq iam list-attached-role-policies --role-name $ROLE --query "AttachedPolicies[].PolicyArn"); do
  aws iam detach-role-policy --role-name $ROLE --policy-arn "$arn"
done
aws iam delete-role --role-name $ROLE 2>/dev/null && echo "  đã xoá role"

echo "Xong. Kiểm tra lại EC2 / Load Balancers / Billing để chắc chắn không còn gì chạy."
