#!/usr/bin/env bash
# Thư viện dùng chung cho verify.sh / cleanup.sh (được `source`, không chạy trực tiếp)

export AWS_REGION="${AWS_REGION:-ap-southeast-1}"
export AWS_DEFAULT_REGION="$AWS_REGION"
export AWS_PAGER=""

PASS=0
FAIL=0
if [ -t 1 ]; then G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; N=$'\e[0m'; else G=""; R=""; Y=""; N=""; fi

pass() { echo "${G}[PASS]${N} $*"; PASS=$((PASS + 1)); }
fail() { echo "${R}[FAIL]${N} $*"; FAIL=$((FAIL + 1)); }
warn() { echo "${Y}[WARN]${N} $*"; }
info() { echo "       $*"; }
section() { echo; echo "== $* =="; }

# check "mô tả" "giá trị thực" "giá trị mong đợi"
check() {
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (thực tế: '${2:-<trống>}', mong đợi: '$3')"; fi
}

# check_true "mô tả" "true|false|..."  -> PASS nếu đúng chuỗi "true"
check_true() {
  if [ "$2" = "true" ]; then pass "$1"; else fail "$1"; fi
}

# awsq <lệnh aws...>: chạy aws với output text, bỏ lỗi, đổi "None" thành rỗng
awsq() { aws "$@" --output text 2>/dev/null | sed 's/^None$//'; }

need() { command -v "$1" >/dev/null 2>&1 || { echo "Thiếu lệnh: $1"; exit 2; }; }

# Cờ dòng lệnh của script gọi (--advanced, --dlq, --chaos ...). Dùng: if has_flag --advanced; then ...
SCRIPT_ARGS=("$@")
has_flag() { local a; for a in "${SCRIPT_ARGS[@]}"; do [ "$a" = "$1" ] && return 0; done; return 1; }

# wait_for <số_lần> <giây_nghỉ> <lệnh...>: thử tới khi lệnh thành công (return 0) hoặc hết số lần
wait_for() {
  local n=$1 s=$2 i; shift 2
  for i in $(seq 1 "$n"); do
    "$@" >/dev/null 2>&1 && return 0
    sleep "$s"
  done
  return 1
}

preflight() {
  need aws; need jq; need curl
  ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null) || {
    echo "Chưa đăng nhập AWS CLI (aws configure / aws sso login)."; exit 2; }
  export ACCOUNT_ID
  echo "Account: $ACCOUNT_ID | Region: $AWS_REGION"
}

summary() {
  echo
  echo "Kết quả: ${PASS} đạt, ${FAIL} chưa đạt"
  if [ "$FAIL" -eq 0 ]; then echo "${G}HOÀN THÀNH LAB${N}"; else echo "${R}Chưa xong – đọc các dòng [FAIL] phía trên${N}"; fi
  [ "$FAIL" -eq 0 ]
}

# ---- dùng cho cleanup.sh ----
confirm() {
  echo "CẢNH BÁO: sắp XOÁ tài nguyên lab ($1) ở account $ACCOUNT_ID, region $AWS_REGION."
  read -r -p "Gõ 'yes' để tiếp tục: " ans
  [ "$ans" = "yes" ] || { echo "Đã huỷ."; exit 1; }
}

# retry <số_lần> <lệnh...>: thử lại mỗi 10 giây (dùng khi chờ ENI/phụ thuộc được giải phóng)
retry() {
  local n=$1 i; shift
  for i in $(seq 1 "$n"); do
    "$@" >/dev/null 2>&1 && return 0
    sleep 10
  done
  return 1
}

# delete_prefix <bucket> <prefix> [region]: xoá mọi version + delete marker dưới một prefix (dọn object thử nghiệm của verify.sh)
delete_prefix() {
  local b=$1 p=$2 region=${3:-$AWS_REGION} out tmp
  tmp=$(mktemp)
  out=$(aws s3api list-object-versions --bucket "$b" --prefix "$p" --region "$region" --output json 2>/dev/null)
  [ -z "$out" ] && out='{}'
  echo "$out" | jq -c '{Objects: ([.Versions[]?, .DeleteMarkers[]?] | map({Key: .Key, VersionId: .VersionId})), Quiet: true}' > "$tmp"
  if [ "$(jq '.Objects | length' "$tmp")" -gt 0 ]; then
    aws s3api delete-objects --bucket "$b" --region "$region" --delete "file://$tmp" >/dev/null 2>&1
  fi
  rm -f "$tmp"
}

# empty_bucket <bucket> [region]: xoá mọi version + delete marker rồi xoá bucket (bỏ qua nếu không tồn tại)
empty_bucket() {
  local b=$1 region=${2:-$AWS_REGION} out n tmp
  aws s3api head-bucket --bucket "$b" --region "$region" >/dev/null 2>&1 || { echo "  (bucket $b không tồn tại – bỏ qua)"; return 0; }
  tmp=$(mktemp)
  while :; do
    out=$(aws s3api list-object-versions --bucket "$b" --region "$region" --max-items 1000 --output json)
    n=$(echo "$out" | jq '[.Versions[]?, .DeleteMarkers[]?] | length')
    [ "$n" -eq 0 ] && break
    echo "$out" | jq -c '{Objects: ([.Versions[]?, .DeleteMarkers[]?] | map({Key: .Key, VersionId: .VersionId})), Quiet: true}' > "$tmp"
    aws s3api delete-objects --bucket "$b" --region "$region" --delete "file://$tmp" >/dev/null
  done
  rm -f "$tmp"
  aws s3api delete-bucket --bucket "$b" --region "$region" && echo "  đã xoá bucket $b"
}
