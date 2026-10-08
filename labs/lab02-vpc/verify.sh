#!/usr/bin/env bash
# Verify Lab 02 – VPC 2 tầng   (thêm --advanced để chấm NACL, endpoint policy, VPC peering, flow logs)
source "$(dirname "$0")/../_common.sh"
preflight
P=saa-lab02

section "1. VPC"
VPC=$(awsq ec2 describe-vpcs --filters "Name=tag:Name,Values=$P-vpc" --query "Vpcs[0].VpcId")
if [ -z "$VPC" ]; then
  fail "Không tìm thấy VPC có tag Name=$P-vpc"
  summary; exit 1
fi
pass "VPC $P-vpc ($VPC)"
check "CIDR của VPC" "$(awsq ec2 describe-vpcs --vpc-ids "$VPC" --query "Vpcs[0].CidrBlock")" "10.20.0.0/16"

section "2. Subnets"
subnet_id() { awsq ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC" "Name=tag:Name,Values=$1" --query "Subnets[0].SubnetId"; }
subnet_field() { awsq ec2 describe-subnets --subnet-ids "$1" --query "Subnets[0].$2"; }
declare -A SID
for s in public-a:10.20.0.0/24 public-b:10.20.1.0/24 private-a:10.20.10.0/24 private-b:10.20.11.0/24; do
  n=${s%%:*}; cidr=${s#*:}
  SID[$n]=$(subnet_id "$P-$n")
  if [ -n "${SID[$n]}" ]; then
    check "Subnet $P-$n có CIDR $cidr" "$(subnet_field "${SID[$n]}" CidrBlock)" "$cidr"
  else
    fail "Không tìm thấy subnet $P-$n"
  fi
done
azpa=$(subnet_field "${SID[public-a]:-x}" AvailabilityZone);  azpb=$(subnet_field "${SID[public-b]:-x}" AvailabilityZone)
azra=$(subnet_field "${SID[private-a]:-x}" AvailabilityZone); azrb=$(subnet_field "${SID[private-b]:-x}" AvailabilityZone)
[ -n "$azpa" ] && [ "$azpa" != "$azpb" ] && pass "Public A/B ở 2 AZ khác nhau ($azpa, $azpb)" || fail "Public A và B phải ở 2 AZ khác nhau"
[ -n "$azra" ] && [ "$azra" != "$azrb" ] && pass "Private A/B ở 2 AZ khác nhau ($azra, $azrb)" || fail "Private A và B phải ở 2 AZ khác nhau"
check "private-a cùng AZ với public-a" "$azra" "$azpa"
check "private-b cùng AZ với public-b" "$azrb" "$azpb"
for n in public-a public-b; do
  check "$P-$n auto-assign public IP = True" "$(subnet_field "${SID[$n]:-x}" MapPublicIpOnLaunch)" "True"
done
for n in private-a private-b; do
  check "$P-$n auto-assign public IP = False" "$(subnet_field "${SID[$n]:-x}" MapPublicIpOnLaunch)" "False"
done

section "3. Internet Gateway"
igw=$(awsq ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$VPC" --query "InternetGateways[0].InternetGatewayId")
[ -n "$igw" ] && pass "IGW $igw đã gắn vào VPC" || fail "VPC chưa có Internet Gateway"

section "4. Route tables"
# Route table hiệu lực của một subnet (association tường minh, nếu không thì main route table)
rt_json() {
  local id=$1 out
  out=$(aws ec2 describe-route-tables --filters "Name=association.subnet-id,Values=$id" --output json 2>/dev/null)
  if [ "$(echo "$out" | jq '.RouteTables | length' 2>/dev/null)" = "0" ] || [ -z "$out" ]; then
    out=$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC" "Name=association.main,Values=true" --output json)
  fi
  echo "$out"
}
for n in public-a public-b; do
  r=$(rt_json "${SID[$n]:-x}" | jq -r --arg igw "$igw" '[.RouteTables[0].Routes[] | select(.DestinationCidrBlock=="0.0.0.0/0" and .GatewayId==$igw)] | length >= 1')
  check_true "$P-$n có route 0.0.0.0/0 → IGW" "$r"
done
for n in private-a private-b; do
  rt=$(rt_json "${SID[$n]:-x}")
  r=$(echo "$rt" | jq -r '[.RouteTables[0].Routes[] | select(.DestinationCidrBlock=="0.0.0.0/0" and ((.GatewayId // "") | startswith("igw-")))] | length == 0')
  check_true "$P-$n KHÔNG có route trực tiếp ra IGW" "$r"
  if [ "$(echo "$rt" | jq -r '[.RouteTables[0].Routes[] | select(.NatGatewayId != null)] | length')" != "0" ]; then
    warn "$P-$n đang dùng NAT Gateway – tốn ~0,05 USD/giờ, nhớ xoá khi xong"
  fi
done
rtname=$(rt_json "${SID[public-a]:-x}" | jq -r '[.RouteTables[0].Tags[]? | select(.Key=="Name") | .Value][0] // ""')
[ "$rtname" = "$P-public-rt" ] && pass "Route table public tên $P-public-rt" || warn "Nên đặt tên route table public là $P-public-rt (hiện: '${rtname}')"

section "5. S3 Gateway Endpoint"
EP=$(aws ec2 describe-vpc-endpoints --filters "Name=vpc-id,Values=$VPC" "Name=service-name,Values=com.amazonaws.$AWS_REGION.s3" --output json 2>/dev/null)
if [ "$(echo "$EP" | jq '.VpcEndpoints | length' 2>/dev/null)" -ge 1 ] 2>/dev/null; then
  check "Loại endpoint = Gateway" "$(echo "$EP" | jq -r '.VpcEndpoints[0].VpcEndpointType')" "Gateway"
  priv_rts=""
  for n in private-a private-b; do
    priv_rts="$priv_rts $(rt_json "${SID[$n]:-x}" | jq -r '.RouteTables[0].RouteTableId')"
  done
  for rtid in $(echo "$priv_rts" | tr ' ' '\n' | sort -u); do
    r=$(echo "$EP" | jq -r --arg rt "$rtid" '(.VpcEndpoints[0].RouteTableIds) | index($rt) != null')
    check_true "Endpoint gắn vào route table private $rtid" "$r"
  done
else
  fail "Chưa có Gateway Endpoint tới S3 trong VPC"
fi

section "6. Bonus: VPC Flow Logs"
fl=$(awsq ec2 describe-flow-logs --filter "Name=resource-id,Values=$VPC" --query "FlowLogs[0].FlowLogId")
[ -n "$fl" ] && pass "VPC có Flow Logs ($fl)" || warn "BONUS: chưa bật VPC Flow Logs"

if has_flag --advanced; then
  echo; echo "######## PHẦN NÂNG CAO ########"

  section "N1. Network ACL tự tạo cho public subnet (stateless, rule theo số thứ tự)"
  NACL=$(aws ec2 describe-network-acls --filters "Name=vpc-id,Values=$VPC" "Name=tag:Name,Values=$P-public-nacl" --output json 2>/dev/null | jq -c '.NetworkAcls[0] // empty')
  if [ -z "$NACL" ]; then
    fail "Không thấy NACL có tag Name=$P-public-nacl"
  else
    pass "Có NACL $P-public-nacl"
    for n in public-a public-b; do
      r=$(echo "$NACL" | jq -r --arg s "${SID[$n]:-x}" '[.Associations[]? | select(.SubnetId==$s)] | length >= 1')
      check_true "NACL gắn vào subnet $P-$n" "$r"
    done
    for n in private-a private-b; do
      r=$(echo "$NACL" | jq -r --arg s "${SID[$n]:-x}" '[.Associations[]? | select(.SubnetId==$s)] | length == 0')
      check_true "Subnet $P-$n KHÔNG dùng NACL này (giữ NACL mặc định)" "$r"
    done
    r=$(echo "$NACL" | jq -r '
      ([.Entries[] | select(.Egress==false and .RuleAction=="deny" and .CidrBlock=="203.0.113.0/24") | .RuleNumber] | min) as $deny
      | ([.Entries[] | select(.Egress==false and .RuleAction=="allow" and .CidrBlock=="0.0.0.0/0" and .RuleNumber<32767) | .RuleNumber] | min) as $allow
      | ($deny != null and $allow != null and $deny < $allow)')
    check_true "Inbound: DENY 203.0.113.0/24 có số thứ tự NHỎ HƠN mọi rule ALLOW 0.0.0.0/0 (NACL xét từ nhỏ lên lớn)" "$r"
    for port in 80 443; do
      r=$(echo "$NACL" | jq -r --argjson p $port '[.Entries[] | select(.Egress==false and .RuleAction=="allow" and (.Protocol=="6" or .Protocol=="-1") and (.PortRange==null or (.PortRange.From<=$p and .PortRange.To>=$p)))] | length >= 1')
      check_true "Inbound cho phép TCP $port" "$r"
    done
    r=$(echo "$NACL" | jq -r '[.Entries[] | select(.Egress==false and .RuleAction=="allow" and (.Protocol=="6" or .Protocol=="-1") and (.PortRange==null or (.PortRange.From<=1024 and .PortRange.To>=65535)))] | length >= 1')
    check_true "Inbound cho phép cổng tạm 1024–65535 (traffic trả về – NACL là stateless)" "$r"
    r=$(echo "$NACL" | jq -r '[.Entries[] | select(.Egress==true and .RuleAction=="allow" and .RuleNumber<32767)] | length >= 1')
    check_true "Outbound có rule ALLOW (stateless: phải mở chiều đi riêng)" "$r"
  fi

  section "N2. Endpoint policy + bucket chỉ nhận request đi qua endpoint (aws:SourceVpce)"
  EPID=$(echo "$EP" | jq -r '.VpcEndpoints[0].VpcEndpointId // ""')
  if [ -z "$EPID" ]; then
    fail "Chưa có S3 Gateway Endpoint (xem phần cơ bản)"
  else
    r=$(echo "$EP" | jq -r '
      (.VpcEndpoints[0].PolicyDocument // "{}" | fromjson | [.Statement] | flatten) as $st
      | ([$st[] | select(.Effect=="Allow" and ((.Action=="*") or (.Action==["*"]) or (.Action=="s3:*") or (.Action==["s3:*"])) and ((.Resource=="*") or (.Resource==["*"])))] | length) == 0
        and ([$st[] | tostring | select(contains("saa-lab02-"))] | length) >= 1')
    check_true "Endpoint policy KHÔNG phải 'cho phép tất cả' và có giới hạn theo bucket saa-lab02-*" "$r"

    PB=$P-$ACCOUNT_ID-private
    if aws s3api head-bucket --bucket "$PB" >/dev/null 2>&1 || [ -n "$(awsq s3api get-bucket-policy --bucket "$PB" --query Policy)" ]; then
      pass "Có bucket $PB"
      pol=$(awsq s3api get-bucket-policy --bucket "$PB" --query Policy)
      if [ -z "$pol" ]; then
        fail "Bucket $PB chưa có bucket policy"
      else
        r=$(echo "$pol" | jq -r --arg e "$EPID" '[.Statement] | flatten | [.[] | select(.Effect=="Deny" and ((.Condition.StringNotEquals["aws:SourceVpce"] // "")==$e))] | length >= 1')
        check_true "Bucket policy: Deny khi aws:SourceVpce ≠ $EPID" "$r"
        r=$(echo "$pol" | jq -r '[.Statement] | flatten | [.[] | select(.Effect=="Deny") | .Action | tostring | select(test("\"s3:\\*\"|\"\\*\"|^s3:\\*$"))] | length == 0')
        check_true "Deny KHÔNG dùng s3:* (tránh tự khoá quản trị – vẫn sửa/xoá được policy)" "$r"
      fi
      err=$(aws s3api list-objects-v2 --bucket "$PB" 2>&1 >/dev/null)
      if echo "$err" | grep -q 'AccessDenied'; then pass "Truy cập từ ngoài VPC (máy của bạn) bị từ chối – kể cả bạn là admin"; else fail "Truy cập từ Internet vào $PB lẽ ra phải bị AccessDenied (nhận: $(echo "$err" | head -1))"; fi
    else
      fail "Chưa có bucket $PB (bucket riêng chỉ truy cập qua endpoint)"
    fi
  fi

  section "N3. VPC Peering (CIDR không chồng nhau, route hai chiều, không bắc cầu)"
  VPCB=$(awsq ec2 describe-vpcs --filters "Name=tag:Name,Values=$P-vpc-b" --query "Vpcs[0].VpcId")
  if [ -z "$VPCB" ]; then
    fail "Không thấy VPC thứ hai có tag Name=$P-vpc-b (CIDR 10.30.0.0/16)"
  else
    pass "VPC thứ hai $P-vpc-b ($VPCB)"
    cidrb=$(awsq ec2 describe-vpcs --vpc-ids "$VPCB" --query "Vpcs[0].CidrBlock")
    check "CIDR VPC B = 10.30.0.0/16 (không chồng 10.20.0.0/16)" "$cidrb" "10.30.0.0/16"
    PCX=$(aws ec2 describe-vpc-peering-connections --filters "Name=tag:Name,Values=$P-peering" "Name=status-code,Values=active" --output json 2>/dev/null | jq -c '.VpcPeeringConnections[0] // empty')
    if [ -z "$PCX" ]; then
      fail "Không thấy peering tên $P-peering ở trạng thái active (đã Accept chưa?)"
    else
      PID=$(echo "$PCX" | jq -r .VpcPeeringConnectionId)
      r=$(echo "$PCX" | jq -r --arg a "$VPC" --arg b "$VPCB" '([.RequesterVpcInfo.VpcId, .AccepterVpcInfo.VpcId] | sort) == ([$a,$b] | sort)')
      check_true "Peering $PID nối đúng $P-vpc ↔ $P-vpc-b" "$r"
      r=$(rt_json "${SID[private-a]:-x}" | jq -r --arg p "$PID" '[.RouteTables[0].Routes[] | select(.DestinationCidrBlock=="10.30.0.0/16" and .VpcPeeringConnectionId==$p)] | length >= 1')
      check_true "Route table private (VPC A): 10.30.0.0/16 → $PID" "$r"
      r=$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPCB" --output json | jq -r --arg p "$PID" '[.RouteTables[].Routes[] | select(.DestinationCidrBlock=="10.20.0.0/16" and .VpcPeeringConnectionId==$p)] | length >= 1')
      check_true "Route table của VPC B: 10.20.0.0/16 → $PID (peering cần route ở CẢ HAI phía)" "$r"
    fi
  fi

  section "N4. VPC Flow Logs"
  FL=$(aws ec2 describe-flow-logs --filter "Name=resource-id,Values=$VPC" --output json 2>/dev/null | jq -c '.FlowLogs[0] // empty')
  if [ -z "$FL" ]; then
    fail "Chưa bật Flow Logs cho $P-vpc"
  else
    pass "Có Flow Logs $(echo "$FL" | jq -r .FlowLogId)"
    tt=$(echo "$FL" | jq -r .TrafficType)
    if [ "$tt" = "ALL" ] || [ "$tt" = "REJECT" ]; then pass "Traffic type = $tt"; else fail "Traffic type phải là ALL hoặc REJECT (hiện: $tt)"; fi
    dt=$(echo "$FL" | jq -r '.LogDestinationType // "cloud-watch-logs"')
    info "Đích: $dt  (S3 rẻ hơn khi lưu lâu; CloudWatch Logs dễ truy vấn bằng Logs Insights)"
  fi
else
  echo; info "Chạy 'bash verify.sh --advanced' để chấm thêm phần nâng cao (NACL, endpoint policy, VPC peering, flow logs)."
fi

summary
