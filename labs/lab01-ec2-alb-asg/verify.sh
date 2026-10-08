#!/usr/bin/env bash
# Verify Lab 01 – EC2 + ALB + ASG
source "$(dirname "$0")/../_common.sh"
preflight
P=saa-lab01

section "1. IAM Role cho EC2"
ROLE=$P-ec2-role
if aws iam get-role --role-name "$ROLE" >/dev/null 2>&1; then
  pass "Role $ROLE tồn tại"
  pol=$(awsq iam list-attached-role-policies --role-name "$ROLE" \
        --query "AttachedPolicies[?PolicyName=='AmazonS3ReadOnlyAccess'].PolicyName")
  check "Role gắn AmazonS3ReadOnlyAccess" "$pol" "AmazonS3ReadOnlyAccess"
  ip=$(awsq iam list-instance-profiles-for-role --role-name "$ROLE" --query "InstanceProfiles[0].InstanceProfileName")
  [ -n "$ip" ] && pass "Có instance profile ($ip)" || fail "Role chưa có instance profile"
else
  fail "Không tìm thấy role $ROLE"
fi

section "2. Security Groups"
sgid() { awsq ec2 describe-security-groups --filters "Name=group-name,Values=$1" --query "SecurityGroups[0].GroupId"; }
ALB_SG=$(sgid $P-alb-sg)
WEB_SG=$(sgid $P-web-sg)
if [ -n "$ALB_SG" ]; then
  r=$(aws ec2 describe-security-groups --group-ids "$ALB_SG" --output json |
      jq -r '[.SecurityGroups[0].IpPermissions[] | select(.FromPort==80) | .IpRanges[].CidrIp] | index("0.0.0.0/0") != null')
  check_true "$P-alb-sg cho phép HTTP 80 từ 0.0.0.0/0" "$r"
else
  fail "Không tìm thấy SG $P-alb-sg"
fi
if [ -n "$WEB_SG" ]; then
  if [ -n "$ALB_SG" ]; then
    r=$(aws ec2 describe-security-groups --group-ids "$WEB_SG" --output json |
        jq -r --arg s "$ALB_SG" '[.SecurityGroups[0].IpPermissions[] | select(.FromPort==80) | .UserIdGroupPairs[].GroupId] | index($s) != null')
    check_true "$P-web-sg nhận HTTP 80 từ SG của ALB (không dùng CIDR)" "$r"
  fi
  r=$(aws ec2 describe-security-groups --group-ids "$WEB_SG" --output json |
      jq -r '[.SecurityGroups[0].IpPermissions[] | .IpRanges[].CidrIp] | index("0.0.0.0/0") == null')
  check_true "$P-web-sg KHÔNG mở bất kỳ cổng nào ra 0.0.0.0/0" "$r"
else
  fail "Không tìm thấy SG $P-web-sg"
fi

section "3. Launch Template"
LT=$(aws ec2 describe-launch-template-versions --launch-template-name $P-lt --versions '$Latest' --output json 2>/dev/null)
if [ -n "$LT" ]; then
  pass "Launch template $P-lt tồn tại"
  r=$(echo "$LT" | jq -r '.LaunchTemplateVersions[0].LaunchTemplateData.IamInstanceProfile != null')
  check_true "Launch template gắn IAM instance profile" "$r"
  r=$(echo "$LT" | jq -r --arg s "$WEB_SG" '(.LaunchTemplateVersions[0].LaunchTemplateData.SecurityGroupIds // []) | index($s) != null')
  check_true "Launch template dùng $P-web-sg" "$r"
  tok=$(echo "$LT" | jq -r '.LaunchTemplateVersions[0].LaunchTemplateData.MetadataOptions.HttpTokens // "optional"')
  if [ "$tok" = "required" ]; then pass "IMDSv2 bắt buộc (HttpTokens=required)"; else warn "Nên bật IMDSv2 only (HttpTokens=required), hiện: $tok"; fi
else
  fail "Không tìm thấy launch template $P-lt"
fi

section "4. ALB & Target Group"
ALB=$(aws elbv2 describe-load-balancers --names $P-alb --output json 2>/dev/null)
ALB_ARN=""; ALB_DNS=""
if [ -n "$ALB" ]; then
  ALB_ARN=$(echo "$ALB" | jq -r '.LoadBalancers[0].LoadBalancerArn')
  ALB_DNS=$(echo "$ALB" | jq -r '.LoadBalancers[0].DNSName')
  pass "ALB $P-alb tồn tại"
  check "ALB loại application" "$(echo "$ALB" | jq -r '.LoadBalancers[0].Type')" "application"
  check "ALB internet-facing" "$(echo "$ALB" | jq -r '.LoadBalancers[0].Scheme')" "internet-facing"
  check "ALB state active" "$(echo "$ALB" | jq -r '.LoadBalancers[0].State.Code')" "active"
  naz=$(echo "$ALB" | jq -r '[.LoadBalancers[0].AvailabilityZones[].ZoneName] | unique | length')
  [ "$naz" -ge 2 ] && pass "ALB trải qua $naz AZ" || fail "ALB chỉ ở $naz AZ (cần ≥ 2)"
  l=$(aws elbv2 describe-listeners --load-balancer-arn "$ALB_ARN" --output json |
      jq -r '[.Listeners[] | select(.Port==80 and .Protocol=="HTTP")] | length')
  [ "$l" -ge 1 ] && pass "Có listener HTTP:80" || fail "Thiếu listener HTTP:80"
else
  fail "Không tìm thấy ALB $P-alb"
fi
TG=$(aws elbv2 describe-target-groups --names $P-tg --output json 2>/dev/null)
TG_ARN=""
if [ -n "$TG" ]; then
  TG_ARN=$(echo "$TG" | jq -r '.TargetGroups[0].TargetGroupArn')
  pass "Target group $P-tg tồn tại"
  h=$(aws elbv2 describe-target-health --target-group-arn "$TG_ARN" --output json |
      jq -r '[.TargetHealthDescriptions[] | select(.TargetHealth.State=="healthy")] | length')
  [ "$h" -ge 2 ] && pass "$h target healthy" || fail "Chỉ $h target healthy (cần ≥ 2; chờ vài phút sau khi ASG khởi tạo)"
else
  fail "Không tìm thấy target group $P-tg"
fi

section "5. Auto Scaling Group"
ASG=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names $P-asg --output json 2>/dev/null)
if [ "$(echo "$ASG" | jq -r '.AutoScalingGroups | length' 2>/dev/null)" = "1" ]; then
  pass "ASG $P-asg tồn tại"
  mn=$(echo "$ASG" | jq -r '.AutoScalingGroups[0].MinSize')
  [ "$mn" -ge 2 ] && pass "MinSize = $mn (≥ 2)" || fail "MinSize = $mn (cần ≥ 2)"
  check "Health check type = ELB" "$(echo "$ASG" | jq -r '.AutoScalingGroups[0].HealthCheckType')" "ELB"
  r=$(echo "$ASG" | jq -r --arg t "$TG_ARN" '(.AutoScalingGroups[0].TargetGroupARNs) | index($t) != null')
  check_true "ASG gắn target group $P-tg" "$r"
  nz=$(echo "$ASG" | jq -r '[.AutoScalingGroups[0].Instances[] | select(.LifecycleState=="InService") | .AvailabilityZone] | unique | length')
  [ "$nz" -ge 2 ] && pass "Instance InService ở $nz AZ khác nhau" || fail "Instance InService chỉ ở $nz AZ (cần ≥ 2)"
  np=$(aws autoscaling describe-policies --auto-scaling-group-name $P-asg --output json |
       jq -r '[.ScalingPolicies[] | select(.PolicyType=="TargetTrackingScaling")] | length')
  [ "$np" -ge 1 ] && pass "Có scaling policy Target Tracking" || fail "Chưa có scaling policy Target Tracking"
else
  fail "Không tìm thấy ASG $P-asg"
fi

section "6. Kiểm tra thực tế qua ALB"
if [ -n "$ALB_DNS" ]; then
  code=$(curl -s -o /dev/null -m 10 -w '%{http_code}' "http://$ALB_DNS/")
  check "GET http://$ALB_DNS/ trả 200" "$code" "200"
  ids=$(for _ in $(seq 1 20); do curl -s -m 5 "http://$ALB_DNS/"; done | grep -o 'i-[0-9a-f]\{8,17\}' | sort -u | wc -l)
  [ "$ids" -ge 2 ] && pass "20 request được $ids instance khác nhau trả lời (load balancing OK)" \
                   || fail "Chỉ $ids instance trả lời trong 20 request (cần ≥ 2)"
else
  fail "Bỏ qua kiểm tra HTTP vì thiếu ALB"
fi

echo
info "Thử thách thủ công: terminate 1 instance rồi chạy lại verify sau ~3–5 phút – ASG phải tự phục hồi."
summary
