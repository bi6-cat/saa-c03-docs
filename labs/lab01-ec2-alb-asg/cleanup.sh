#!/usr/bin/env bash
# Cleanup Lab 01 – xoá ASG, ALB, TG, Lambda (phần nâng cao), LT, SG, IAM role
source "$(dirname "$0")/../_common.sh"
preflight
P=saa-lab01
confirm "$P-*"

echo "- Xoá Auto Scaling group (kéo theo terminate instance, scheduled action, scaling policy)..."
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
for tg in $P-tg $P-api-tg; do
  TG_ARN=$(awsq elbv2 describe-target-groups --names $tg --query 'TargetGroups[0].TargetGroupArn')
  [ -n "$TG_ARN" ] && { retry 12 aws elbv2 delete-target-group --target-group-arn "$TG_ARN" && echo "  đã xoá $tg"; }
done

echo "- Xoá Lambda $P-api (phần nâng cao) + role và log group do Console tạo..."
FN=$P-api
FN_ROLE=$(awsq lambda get-function-configuration --function-name $FN --query Role)
if aws lambda delete-function --function-name $FN 2>/dev/null; then echo "  đã xoá function $FN"; fi
aws logs delete-log-group --log-group-name /aws/lambda/$FN 2>/dev/null && echo "  đã xoá log group /aws/lambda/$FN"
LR=${FN_ROLE##*/}
# Chỉ xoá role mang tên của lab (Console đặt dạng saa-lab01-api-role-xxxx)
if [ -n "$LR" ] && [[ "$LR" == $P-* ]]; then
  for arn in $(awsq iam list-attached-role-policies --role-name "$LR" --query "AttachedPolicies[].PolicyArn"); do
    aws iam detach-role-policy --role-name "$LR" --policy-arn "$arn"
    # Policy do Console tự sinh (AWSLambdaBasicExecutionRole-<uuid>) nằm trong account, không còn dùng → xoá
    if [[ "$arn" == arn:aws:iam::$ACCOUNT_ID:policy/service-role/AWSLambdaBasicExecutionRole-* ]]; then
      aws iam delete-policy --policy-arn "$arn" 2>/dev/null && echo "  đã xoá policy ${arn##*/}"
    fi
  done
  for pn in $(awsq iam list-role-policies --role-name "$LR" --query "PolicyNames[]"); do
    aws iam delete-role-policy --role-name "$LR" --policy-name "$pn"
  done
  aws iam delete-role --role-name "$LR" 2>/dev/null && echo "  đã xoá role $LR"
elif [ -n "$LR" ]; then
  echo "  Lambda dùng role '$LR' (không mang tên lab) – KHÔNG xoá, hãy tự kiểm tra"
fi

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
for pn in $(awsq iam list-role-policies --role-name $ROLE --query "PolicyNames[]"); do
  aws iam delete-role-policy --role-name $ROLE --policy-name "$pn"
done
aws iam delete-role --role-name $ROLE 2>/dev/null && echo "  đã xoá role"

echo "Xong. Kiểm tra lại EC2 / Load Balancers / Billing để chắc chắn không còn gì chạy."
