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
      jq -r '[.SecurityGroups[0].IpPermissions[] | (.IpRanges[]?.CidrIp), (.Ipv6Ranges[]?.CidrIpv6)] | (index("0.0.0.0/0") == null and index("::/0") == null)')
  check_true "$P-web-sg KHÔNG mở bất kỳ cổng nào ra 0.0.0.0/0 hoặc ::/0" "$r"
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

# ---------- dữ liệu dùng chung cho phần nâng cao / game day ----------
asg_json() { aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names $P-asg --output json 2>/dev/null | jq -c '.AutoScalingGroups[0] // empty'; }
inservice_ids() { asg_json | jq -r '.Instances[]? | select(.LifecycleState=="InService") | .InstanceId'; }
healthy_count() {
  local n
  n=$(aws elbv2 describe-target-health --target-group-arn "$TG_ARN" --output json 2>/dev/null |
      jq '[.TargetHealthDescriptions[] | select(.TargetHealth.State=="healthy")] | length')
  echo "${n:-0}"
}

if has_flag --advanced; then
  echo; echo "######## PHẦN NÂNG CAO ########"
  ASG_J=$(asg_json)
  INSVC=$(echo "$ASG_J" | jq -r '[.Instances[]? | select(.LifecycleState=="InService") | .InstanceId] | join(" ")')
  N_INSVC=$(echo $INSVC | wc -w)

  # Phiên bản launch template mà ASG thực sự dùng ($Latest / $Default / số cụ thể)
  LT_SPEC=$(echo "$ASG_J" | jq -c '.LaunchTemplate // .MixedInstancesPolicy.LaunchTemplate.LaunchTemplateSpecification // empty')
  LT_META=$(aws ec2 describe-launch-templates --launch-template-names $P-lt --output json 2>/dev/null | jq -c '.LaunchTemplates[0] // empty')
  LT_VER=""; LTD=""
  if [ -n "$LT_SPEC" ] && [ -n "$LT_META" ]; then
    v=$(echo "$LT_SPEC" | jq -r '.Version // "$Default"')
    case "$v" in
      '$Latest')  LT_VER=$(echo "$LT_META" | jq -r .LatestVersionNumber) ;;
      '$Default') LT_VER=$(echo "$LT_META" | jq -r .DefaultVersionNumber) ;;
      *)          LT_VER=$v ;;
    esac
    LTD=$(aws ec2 describe-launch-template-versions --launch-template-name $P-lt --versions "$LT_VER" --output json 2>/dev/null |
          jq -c '.LaunchTemplateVersions[0].LaunchTemplateData // empty')
  fi
  [ -n "$LT_VER" ] && info "ASG đang dùng $P-lt version $LT_VER (khai báo: $(echo "$LT_SPEC" | jq -r '.Version // "$Default"'))"

  section "N1. Session Manager thay cho SSH"
  pol=$(awsq iam list-attached-role-policies --role-name $P-ec2-role \
        --query "AttachedPolicies[?PolicyName=='AmazonSSMManagedInstanceCore'].PolicyName")
  check "Role $P-ec2-role gắn AmazonSSMManagedInstanceCore" "$pol" "AmazonSSMManagedInstanceCore"
  if [ -n "$LTD" ]; then
    kn=$(echo "$LTD" | jq -r '.KeyName // empty')
    [ -z "$kn" ] && pass "Launch template v$LT_VER không gắn key pair" \
                 || fail "Launch template v$LT_VER vẫn gắn key pair '$kn' – bỏ key pair, truy cập bằng Session Manager"
  else
    fail "Không xác định được launch template version mà ASG đang dùng"
  fi
  if [ "$N_INSVC" -gt 0 ]; then
    on=$(aws ssm describe-instance-information --filters "Key=InstanceIds,Values=$(echo $INSVC | tr ' ' ',')" --output json 2>/dev/null |
         jq '[.InstanceInformationList[] | select(.PingStatus=="Online")] | length')
    [ "${on:-0}" -ge "$N_INSVC" ] && pass "$on/$N_INSVC instance InService đã Online trong Systems Manager" \
      || fail "Chỉ ${on:-0}/$N_INSVC instance Online trong SSM (instance tạo trước khi gắn policy có thể rất lâu mới đăng ký – instance refresh ở N3 sẽ giải quyết)"
  else
    fail "ASG không có instance InService để kiểm tra SSM"
  fi

  section "N2. Mixed instances: On-Demand nền + Spot"
  MIP=$(echo "$ASG_J" | jq -c '.MixedInstancesPolicy // empty')
  if [ -z "$MIP" ]; then
    fail "ASG chưa dùng mixed instances policy (Edit → Instance type requirements → Override launch template)"
  else
    pass "ASG dùng mixed instances policy"
    nt=$(echo "$MIP" | jq '[.LaunchTemplate.Overrides[]?.InstanceType // empty] | unique | length')
    ir=$(echo "$MIP" | jq '[.LaunchTemplate.Overrides[]? | select(.InstanceRequirements != null)] | length')
    if [ "${nt:-0}" -ge 2 ] || [ "${ir:-0}" -ge 1 ]; then pass "Đa dạng loại instance ($nt loại khai báo; $ir bộ instance requirements)"
    else fail "Cần ≥ 2 loại instance (mỗi loại × AZ là một Spot pool riêng → ít bị thu hồi đồng loạt)"; fi
    base=$(echo "$MIP" | jq -r '.InstancesDistribution.OnDemandBaseCapacity // 0')
    pct=$(echo "$MIP" | jq -r '.InstancesDistribution.OnDemandPercentageAboveBaseCapacity // 100')
    [ "$base" -ge 1 ] && pass "On-Demand base capacity = $base" || fail "On-Demand base capacity = $base (cần ≥ 1 để luôn còn instance không bị thu hồi)"
    [ "$pct" -lt 100 ] && pass "Phần vượt base: $pct% On-Demand / $((100 - pct))% Spot" || fail "Phần vượt base đang 100% On-Demand – chưa dùng Spot"
    check "Spot allocation strategy" "$(echo "$MIP" | jq -r '.InstancesDistribution.SpotAllocationStrategy // empty')" "price-capacity-optimized"
  fi
  check_true "Capacity Rebalancing bật" "$(echo "$ASG_J" | jq -r '.CapacityRebalance // false')"
  if [ "$N_INSVC" -gt 0 ]; then
    LC=$(aws ec2 describe-instances --instance-ids $INSVC --output json 2>/dev/null |
         jq -r '[.Reservations[].Instances[] | (.InstanceLifecycle // "on-demand")]')
    ns=$(echo "$LC" | jq '[.[] | select(.=="spot")] | length')
    nd=$(echo "$LC" | jq '[.[] | select(.=="on-demand")] | length')
    ns=${ns:-0}; nd=${nd:-0}
    if [ "$ns" -ge 1 ] && [ "$nd" -ge 1 ]; then pass "Đang chạy $nd On-Demand + $ns Spot"
    else fail "Đang chạy $nd On-Demand + $ns Spot (cần cả hai – đã chạy instance refresh ở N3 chưa?)"; fi
  fi

  section "N3. Launch template v2 + Instance refresh"
  latest=$(echo "$LT_META" | jq -r '.LatestVersionNumber // 0')
  [ "${latest:-0}" -ge 2 ] && pass "Launch template có $latest version" || fail "Launch template mới có ${latest:-0} version (cần tạo version mới)"
  if [ -n "$LTD" ]; then
    check "IMDSv2 bắt buộc (HttpTokens) ở v$LT_VER" "$(echo "$LTD" | jq -r '.MetadataOptions.HttpTokens // "optional"')" "required"
    r=$(echo "$LTD" | jq -r '[.BlockDeviceMappings[]?.Ebs.VolumeType] | index("gp3") != null')
    check_true "Launch template v$LT_VER khai báo EBS gp3" "$r"
    enc_lt=$(echo "$LTD" | jq -r '[.BlockDeviceMappings[]?.Ebs.Encrypted] | index(true) != null')
    enc_def=$(awsq ec2 get-ebs-encryption-by-default --query EbsEncryptionByDefault)
    if [ "$enc_lt" = "true" ]; then pass "Launch template v$LT_VER bật mã hoá EBS"
    elif [ "$enc_def" = "True" ]; then pass "Region bật EBS encryption by default"
    else fail "EBS chưa mã hoá (bật Encrypted trong launch template hoặc EBS encryption by default)"; fi
  fi
  IRS=$(aws autoscaling describe-instance-refreshes --auto-scaling-group-name $P-asg --output json 2>/dev/null |
        jq -r '.InstanceRefreshes | sort_by(.StartTime) | last | .Status // empty')
  check "Instance refresh gần nhất" "$IRS" "Successful"
  if [ -n "$LT_VER" ]; then
    stale=$(echo "$ASG_J" | jq -r --arg v "$LT_VER" '[.Instances[]? | select(.LifecycleState=="InService") | select((.LaunchTemplate.Version // "") != $v)] | length')
    [ "$stale" = "0" ] && pass "Mọi instance InService chạy launch template v$LT_VER" \
                       || fail "$stale instance InService còn chạy version cũ (chạy instance refresh)"
  fi
  if [ "$N_INSVC" -gt 0 ]; then
    bad=$(aws ec2 describe-volumes --filters "Name=attachment.instance-id,Values=$(echo $INSVC | tr ' ' ',')" --output json 2>/dev/null |
          jq -r '[.Volumes[] | select(.Encrypted != true or .VolumeType != "gp3") | .VolumeId] | join(" ")')
    [ -z "$bad" ] && pass "Mọi EBS volume của instance InService đều gp3 + mã hoá" || fail "Volume chưa đạt (gp3 + encrypted): $bad"
  fi
  if [ -n "$ALB_DNS" ]; then
    bodies=$(for _ in $(seq 1 20); do curl -s -m 5 "http://$ALB_DNS/" | tr -d '\n'; echo; done)
    check "Số response là bản v2 (trên 20 request)" "$(echo "$bodies" | grep -c 'saa-lab01 v2')" "20"
    echo "$bodies" | grep -q 'spot' && info "Có response đến từ instance Spot (thấy chữ 'spot' trong trang)"
  fi

  section "N4. Health check và draining"
  TGJ=$(echo "$TG" | jq -c '.TargetGroups[0] // empty' 2>/dev/null)
  if [ -n "$TGJ" ]; then
    check "Health check path" "$(echo "$TGJ" | jq -r .HealthCheckPath)" "/health"
    iv=$(echo "$TGJ" | jq -r .HealthCheckIntervalSeconds); ht=$(echo "$TGJ" | jq -r .HealthyThresholdCount)
    [ "$iv" -le 15 ] && pass "Health check interval = ${iv}s (≤ 15)" || fail "Health check interval = ${iv}s (cần ≤ 15 để phát hiện lỗi nhanh)"
    [ "$ht" -le 3 ] && pass "Healthy threshold = $ht (≤ 3)" || fail "Healthy threshold = $ht (cần ≤ 3 để instance mới nhận traffic sớm)"
    dd=$(aws elbv2 describe-target-group-attributes --target-group-arn "$TG_ARN" --output json |
         jq -r '.Attributes[] | select(.Key=="deregistration_delay.timeout_seconds") | .Value')
    [ "${dd:-300}" -le 60 ] && pass "Deregistration delay = ${dd}s (≤ 60)" || fail "Deregistration delay = ${dd:-300}s (cần ≤ 60; mặc định 300 làm deploy/scale-in chậm)"
  else
    fail "Không đọc được target group $P-tg"
  fi
  if [ -n "$ALB_DNS" ]; then
    check "GET /health qua ALB trả 200" "$(curl -s -o /dev/null -m 10 -w '%{http_code}' "http://$ALB_DNS/health")" "200"
  fi
  [ -n "$ASG_J" ] && info "ASG health check grace period hiện tại: $(echo "$ASG_J" | jq -r '.HealthCheckGracePeriod')s"

  section "N5. Routing theo path: Lambda target + fixed response"
  FN=$P-api
  if aws lambda get-function --function-name $FN >/dev/null 2>&1; then
    pass "Lambda $FN tồn tại"
    r=$(aws lambda get-policy --function-name $FN --query Policy --output text 2>/dev/null |
        jq -r '[.Statement[] | .Principal.Service? // empty] | index("elasticloadbalancing.amazonaws.com") != null' 2>/dev/null)
    check_true "Resource-based policy của Lambda cho phép elasticloadbalancing.amazonaws.com gọi" "$r"
  else
    fail "Không tìm thấy Lambda $FN"
  fi
  API_TG=$(aws elbv2 describe-target-groups --names $P-api-tg --output json 2>/dev/null | jq -c '.TargetGroups[0] // empty')
  API_TG_ARN=""
  if [ -n "$API_TG" ]; then
    API_TG_ARN=$(echo "$API_TG" | jq -r .TargetGroupArn)
    check "Target group $P-api-tg có target type" "$(echo "$API_TG" | jq -r .TargetType)" "lambda"
    r=$(aws elbv2 describe-target-health --target-group-arn "$API_TG_ARN" --output json |
        jq -r --arg f ":function:$FN" '[.TargetHealthDescriptions[].Target.Id | select(contains($f))] | length >= 1')
    check_true "Lambda $FN đã đăng ký vào $P-api-tg" "$r"
  else
    fail "Không tìm thấy target group $P-api-tg"
  fi
  if [ -n "$ALB_ARN" ]; then
    LIS=$(aws elbv2 describe-listeners --load-balancer-arn "$ALB_ARN" --output json | jq -r '[.Listeners[] | select(.Port==80)][0].ListenerArn // empty')
    RULES=$(aws elbv2 describe-rules --listener-arn "$LIS" --output json 2>/dev/null)
    r=$(echo "$RULES" | jq -r --arg t "$API_TG_ARN" '
      [.Rules[]
       | select(any(.Conditions[]?; .Field=="path-pattern" and (((.PathPatternConfig.Values // .Values) // []) | index("/api/*") != null)))
       | select(any(.Actions[]?; .Type=="forward" and ((.TargetGroupArn // "") == $t or any(.ForwardConfig.TargetGroups[]?; .TargetGroupArn == $t))))
      ] | length >= 1')
    check_true "Listener rule: path /api/* → forward $P-api-tg" "$r"
    r=$(echo "$RULES" | jq -r '
      [.Rules[]
       | select(any(.Conditions[]?; .Field=="path-pattern" and any(((.PathPatternConfig.Values // .Values) // [])[]; startswith("/admin"))))
       | select(any(.Actions[]?; .Type=="fixed-response" and .FixedResponseConfig.StatusCode=="403"))
      ] | length >= 1')
    check_true "Listener rule: path /admin* → fixed response 403" "$r"
  fi
  if [ -n "$ALB_DNS" ]; then
    body=$(curl -s -m 10 "http://$ALB_DNS/api/orders?id=1")
    echo "$body" | grep -q '"source": *"lambda"' && pass "GET /api/orders được Lambda trả lời" \
      || fail "GET /api/orders không phải từ Lambda (nhận: '$(echo "$body" | head -c 120)')"
    check "GET /admin bị ALB chặn" "$(curl -s -o /dev/null -m 10 -w '%{http_code}' "http://$ALB_DNS/admin")" "403"
    curl -s -m 10 "http://$ALB_DNS/" | grep -q 'saa-lab01' && pass "GET / vẫn tới EC2 (default rule)" || fail "GET / không còn tới EC2"
  fi

  section "N6. Scaling theo lịch và theo số request"
  SA=$(aws autoscaling describe-scheduled-actions --auto-scaling-group-name $P-asg --output json 2>/dev/null)
  for n in business-hours after-hours; do
    rec=$(echo "$SA" | jq -r --arg n "$P-$n" '.ScheduledUpdateGroupActions[]? | select(.ScheduledActionName==$n) | .Recurrence // empty')
    tz=$(echo "$SA" | jq -r --arg n "$P-$n" '.ScheduledUpdateGroupActions[]? | select(.ScheduledActionName==$n) | .TimeZone // "UTC"')
    [ -n "$rec" ] && pass "Scheduled action $P-$n lặp lại: '$rec' ($tz)" || fail "Thiếu scheduled action lặp lại $P-$n"
  done
  bd=$(echo "$SA" | jq -r --arg n "$P-business-hours" '.ScheduledUpdateGroupActions[]? | select(.ScheduledActionName==$n) | .DesiredCapacity // 0')
  ad=$(echo "$SA" | jq -r --arg n "$P-after-hours" '.ScheduledUpdateGroupActions[]? | select(.ScheduledActionName==$n) | .DesiredCapacity // 0')
  [ "${bd:-0}" -gt "${ad:-0}" ] && pass "Desired giờ làm việc ($bd) > ngoài giờ ($ad)" || fail "Desired giờ làm việc (${bd:-0}) phải lớn hơn ngoài giờ (${ad:-0})"
  POL=$(aws autoscaling describe-policies --auto-scaling-group-name $P-asg --output json 2>/dev/null)
  nr=$(echo "$POL" | jq '[.ScalingPolicies[] | select(.PolicyType=="TargetTrackingScaling" and .TargetTrackingConfiguration.PredefinedMetricSpecification.PredefinedMetricType=="ALBRequestCountPerTarget")] | length')
  [ "${nr:-0}" -ge 1 ] && pass "Có target tracking theo ALBRequestCountPerTarget" || fail "Chưa có target tracking theo ALB request count per target"
  ntt=$(echo "$POL" | jq '[.ScalingPolicies[] | select(.PolicyType=="TargetTrackingScaling")] | length')
  [ "${ntt:-0}" -ge 1 ] && info "Tổng $ntt target tracking policy: scale-out khi BẤT KỲ policy nào yêu cầu, scale-in chỉ khi TẤT CẢ đồng ý."
fi

if has_flag --chaos; then
  echo; echo "######## GAME DAY ########"
  if [ -z "$ALB_DNS" ] || [ -z "$TG_ARN" ]; then
    fail "Bỏ qua game day vì thiếu ALB hoặc target group"
  else
    DES=$(asg_json | jq -r '.DesiredCapacity // 2')
    TOTAL=0; ERR=0
    probe() {
      local c; c=$(curl -s -o /dev/null -m 3 -w '%{http_code}' "http://$ALB_DNS/")
      TOTAL=$((TOTAL + 1)); [ "$c" = "200" ] || ERR=$((ERR + 1))
    }
    # Hệ thống đã ổn định: đủ desired instance healthy và target không ở trạng thái chuyển tiếp
    stable() { [ "$(healthy_count)" -ge "$DES" ] && [ "$(inservice_ids | wc -l)" -ge "$DES" ]; }
    echo "Chờ hệ thống ổn định ($DES target healthy) trước khi bắt đầu..."
    wait_for 40 15 stable || warn "Hệ thống chưa ổn định sau 10 phút – kết quả có thể không chính xác"

    section "C1. App chết nhưng máy vẫn sống (dừng httpd bằng SSM Run Command)"
    X=""
    for id in $(inservice_ids); do
      s=$(awsq ssm describe-instance-information --filters "Key=InstanceIds,Values=$id" --query 'InstanceInformationList[0].PingStatus')
      [ "$s" = "Online" ] && { X=$id; break; }
    done
    if [ -z "$X" ]; then
      warn "Không có instance nào Online trong SSM – bỏ qua C1 (làm N1 trước)"
    else
      CMD=$(awsq ssm send-command --instance-ids "$X" --document-name AWS-RunShellScript \
            --comment "saa-lab01 game day" --parameters 'commands=["systemctl stop httpd"]' --query Command.CommandId)
      info "Đã gửi lệnh dừng httpd trên $X (command $CMD). Bắt đầu đo..."
      TOTAL=0; ERR=0; T0=$(date +%s); DET=""; REP=""
      while [ $(( $(date +%s) - T0 )) -lt 720 ]; do
        probe
        st=$(awsq elbv2 describe-target-health --target-group-arn "$TG_ARN" --targets "Id=$X,Port=80" \
             --query 'TargetHealthDescriptions[0].TargetHealth.State')
        [ -z "$DET" ] && [ "$st" != "healthy" ] && DET=$(( $(date +%s) - T0 )) && info "ALB phát hiện $X không healthy sau ${DET}s (trạng thái: ${st:-unused})"
        if [ -n "$DET" ] && ! inservice_ids | grep -q "$X" && stable; then REP=$(( $(date +%s) - T0 )); break; fi
        sleep 2
      done
      info "Trong lúc sự cố: $ERR/$TOTAL request lỗi"
      if [ -n "$REP" ]; then
        pass "ASG đã thay instance chết app và trở lại $DES target healthy sau ${REP}s"
        info "Lỗi chỉ xảy ra trong khoảng trước khi ALB phát hiện (≈ interval × unhealthy threshold)."
      else
        fail "Sau 12 phút ASG chưa thay $X. Kiểm tra: Health check type của ASG có phải ELB không? (EC2 status check vẫn OK vì máy còn chạy)"
      fi
    fi

    section "C2. Thay máy có kế hoạch (terminate qua ASG, giữ desired)"
    Y=$(inservice_ids | head -1)
    if [ -z "$Y" ]; then
      fail "Không có instance InService để thử"
    else
      aws autoscaling terminate-instance-in-auto-scaling-group --instance-id "$Y" --no-should-decrement-desired-capacity >/dev/null
      info "Đã yêu cầu ASG terminate $Y. Bắn request liên tục trong lúc ASG rút và thay instance..."
      TOTAL=0; ERR=0; T0=$(date +%s); REP=""
      while [ $(( $(date +%s) - T0 )) -lt 720 ]; do
        probe
        if [ $(( $(date +%s) - T0 )) -ge 30 ] && ! inservice_ids | grep -q "$Y" && stable; then REP=$(( $(date +%s) - T0 )); break; fi
        sleep 2
      done
      if [ "$ERR" -eq 0 ]; then pass "0/$TOTAL request lỗi – deregistration delay giúp rút instance êm"
      elif [ "$ERR" -le 2 ]; then warn "$ERR/$TOTAL request lỗi (thấp, có thể do mạng; kỳ vọng là 0)"
      else fail "$ERR/$TOTAL request lỗi khi thay máy có kế hoạch – kiểm tra deregistration delay và health check"; fi
      [ -n "$REP" ] && pass "ASG đã thay $Y và trở lại $DES target healthy sau ${REP}s" \
                    || fail "Sau 12 phút ASG chưa trở lại $DES target healthy"
    fi
  fi
fi

if ! has_flag --advanced && ! has_flag --chaos; then
  echo
  info "Thử thách thủ công: terminate 1 instance rồi chạy lại verify sau ~3–5 phút – ASG phải tự phục hồi."
  info "Chạy 'bash verify.sh --advanced' để chấm phần nâng cao (N1–N6), 'bash verify.sh --chaos' cho game day."
fi
summary
