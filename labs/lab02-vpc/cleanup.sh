#!/usr/bin/env bash
# Cleanup Lab 02 – xoá VPC saa-lab02-vpc, saa-lab02-vpc-b (nâng cao), peering và bucket đi kèm
source "$(dirname "$0")/../_common.sh"
preflight
P=saa-lab02
confirm "$P-*"

vpc_id() { awsq ec2 describe-vpcs --filters "Name=tag:Name,Values=$1" --query "Vpcs[0].VpcId"; }
VPC_A=$(vpc_id $P-vpc)
VPC_B=$(vpc_id $P-vpc-b)
[ -z "$VPC_A" ] && [ -z "$VPC_B" ] && echo "Không thấy VPC $P-vpc / $P-vpc-b – chỉ dọn bucket (nếu có)."

echo "- Xoá VPC peering (nâng cao)..."
# Lọc bằng jq theo cả hai phía của peering, khử trùng lặp (không dựa vào filter phía server)
for pcx in $(aws ec2 describe-vpc-peering-connections --output json 2>/dev/null |
    jq -r --arg a "${VPC_A:-none}" --arg b "${VPC_B:-none}" '
      .VpcPeeringConnections[]? | select(.Status.Code | IN("active","pending-acceptance","provisioning"))
      | select([.RequesterVpcInfo.VpcId, .AccepterVpcInfo.VpcId] | any(. == $a or . == $b)) | .VpcPeeringConnectionId' | sort -u); do
  aws ec2 delete-vpc-peering-connection --vpc-peering-connection-id "$pcx" >/dev/null && echo "  đã xoá $pcx"
done

echo "- Xoá bucket phần nâng cao (bỏ bucket policy trước)..."
for b in "$P-$ACCOUNT_ID-private" "$P-$ACCOUNT_ID-flowlogs"; do
  aws s3api delete-bucket-policy --bucket "$b" >/dev/null 2>&1
  empty_bucket "$b"
done

delete_vpc() {
  local VPC=$1
  echo "== VPC: $VPC =="

  echo "- Xoá Flow Logs..."
  for f in $(awsq ec2 describe-flow-logs --filter "Name=resource-id,Values=$VPC" --query "FlowLogs[].FlowLogId"); do
    aws ec2 delete-flow-logs --flow-log-ids "$f" >/dev/null
  done

  echo "- Xoá NAT Gateway (nếu có, rất tốn tiền nếu để quên)..."
  for n in $(awsq ec2 describe-nat-gateways --filter "Name=vpc-id,Values=$VPC" "Name=state,Values=available,pending" --query "NatGateways[].NatGatewayId"); do
    aws ec2 delete-nat-gateway --nat-gateway-id "$n" >/dev/null
    echo "  đang xoá $n (chờ)..."
    for _ in $(seq 1 30); do
      st=$(awsq ec2 describe-nat-gateways --nat-gateway-ids "$n" --query "NatGateways[0].State")
      [ "$st" = "deleted" ] && break
      sleep 10
    done
    # Elastic IP của NAT (nếu bạn tự cấp) cần release thủ công: kiểm tra EC2 -> Elastic IPs
  done

  echo "- Xoá VPC endpoints..."
  EPS=$(awsq ec2 describe-vpc-endpoints --filters "Name=vpc-id,Values=$VPC" --query "VpcEndpoints[].VpcEndpointId")
  [ -n "$EPS" ] && aws ec2 delete-vpc-endpoints --vpc-endpoint-ids $EPS >/dev/null

  echo "- Gỡ & xoá Internet Gateway..."
  for igw in $(awsq ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$VPC" --query "InternetGateways[].InternetGatewayId"); do
    aws ec2 detach-internet-gateway --internet-gateway-id "$igw" --vpc-id "$VPC"
    aws ec2 delete-internet-gateway --internet-gateway-id "$igw"
  done

  echo "- Xoá subnets..."
  for s in $(awsq ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC" --query "Subnets[].SubnetId"); do
    retry 6 aws ec2 delete-subnet --subnet-id "$s" || echo "  không xoá được $s (còn ENI/instance?)"
  done

  echo "- Xoá route tables (không phải main)..."
  for rt in $(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC" --output json |
              jq -r '.RouteTables[] | select([.Associations[]? | .Main] | any | not) | .RouteTableId'); do
    for assoc in $(awsq ec2 describe-route-tables --route-table-ids "$rt" --query "RouteTables[0].Associations[].RouteTableAssociationId"); do
      aws ec2 disassociate-route-table --association-id "$assoc" >/dev/null 2>&1
    done
    aws ec2 delete-route-table --route-table-id "$rt" 2>/dev/null && echo "  đã xoá $rt"
  done

  echo "- Xoá security group / NACL do bạn tạo (không phải default)..."
  for sg in $(awsq ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC" --query "SecurityGroups[?GroupName!='default'].GroupId"); do
    aws ec2 delete-security-group --group-id "$sg" 2>/dev/null
  done
  for nacl in $(aws ec2 describe-network-acls --filters "Name=vpc-id,Values=$VPC" --output json | jq -r '.NetworkAcls[] | select(.IsDefault|not) | .NetworkAclId'); do
    # subnet đã bị xoá ở bước trên nên NACL tự do; nếu còn association thì đã được trả về NACL mặc định
    aws ec2 delete-network-acl --network-acl-id "$nacl" 2>/dev/null && echo "  đã xoá NACL $nacl" || echo "  CHƯA xoá được NACL $nacl (còn subnet gắn?)"
  done

  echo "- Xoá VPC..."
  aws ec2 delete-vpc --vpc-id "$VPC" && echo "  đã xoá $VPC" || echo "  CHƯA xoá được VPC $VPC – còn phụ thuộc, kiểm tra Console."
}

for v in $VPC_B $VPC_A; do delete_vpc "$v"; done
echo "Nếu bạn bật Flow Logs về CloudWatch Logs, hãy xoá thêm log group tương ứng để khỏi tốn phí lưu trữ."
