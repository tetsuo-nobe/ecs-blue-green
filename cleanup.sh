#!/usr/bin/env bash
# ============================================================
# ECS Blue/Green デプロイ ハンズオン 環境クリーンアップスクリプト（講師用）
#
# 削除対象:
#   - CloudFormation スタック ecs-blue-green
#     （VPC・ALB・ECS クラスター/サービス・Lambda・IAM ロールなど）
#   - タスク定義 myweb-task-blue / myweb-task-green の ACTIVE なリビジョン
#   - Lambda のロググループ /aws/lambda/ecs-deployment-hook
#   - ECR リポジトリ myweb（イメージを含む）
#   - ローカル（CloudShell）の myweb コンテナイメージ
#
# 使い方（CloudShell で実行）:
#   bash cleanup.sh       # 削除対象を表示し、確認してから実行
#   bash cleanup.sh -y    # 確認なしで実行
#
# 存在しないリソースはスキップするため、途中で失敗した場合も再実行できます。
# ============================================================
set -uo pipefail

# ------------------------------------------------------------
# 設定値（ハンズオンで作成したリソース名）
# ------------------------------------------------------------
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-ap-northeast-1}}"
STACK_NAME="ecs-blue-green"
ECR_REPOSITORY="myweb"
TASK_FAMILIES=("myweb-task-blue" "myweb-task-green")
LOG_GROUPS=("/aws/lambda/ecs-deployment-hook")

ASSUME_YES=false
if [[ "${1:-}" == "-y" ]]; then
  ASSUME_YES=true
fi

info() { echo "[INFO] $*"; }
warn() { echo "[WARN] $*" >&2; }

# ------------------------------------------------------------
# 事前確認
# ------------------------------------------------------------
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null)
if [[ -z "$ACCOUNT_ID" ]]; then
  warn "AWS の認証情報を取得できません。AWS CLI の設定を確認してください。"
  exit 1
fi

cat <<EOF
============================================================
 ECS Blue/Green ハンズオン環境を削除します
============================================================
 アカウント     : $ACCOUNT_ID
 リージョン     : $REGION
 スタック       : $STACK_NAME
 タスク定義     : ${TASK_FAMILIES[*]}
 ロググループ   : ${LOG_GROUPS[*]}
 ECR リポジトリ : $ECR_REPOSITORY（イメージを含む）
 ローカル       : $ECR_REPOSITORY のコンテナイメージ
============================================================
EOF

if [[ "$ASSUME_YES" != true ]]; then
  read -r -p "削除を実行しますか？ (yes/no): " answer
  if [[ "$answer" != "yes" ]]; then
    info "中止しました。"
    exit 0
  fi
fi

# ------------------------------------------------------------
# 1. CloudFormation スタックの削除
# ------------------------------------------------------------
delete_stack() {
  if ! aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$REGION" >/dev/null 2>&1; then
    info "スタック $STACK_NAME は存在しません（スキップ）"
    return
  fi
  info "スタック $STACK_NAME を削除します（完了まで数分かかります）"
  aws cloudformation delete-stack --stack-name "$STACK_NAME" --region "$REGION"
  if aws cloudformation wait stack-delete-complete --stack-name "$STACK_NAME" --region "$REGION"; then
    info "スタック $STACK_NAME を削除しました"
  else
    warn "スタック $STACK_NAME の削除に失敗しました。CloudFormation コンソールでイベントを確認してください"
  fi
}

# ------------------------------------------------------------
# 2. タスク定義の登録解除（ACTIVE なリビジョンが残っている場合）
# ------------------------------------------------------------
deregister_task_definitions() {
  local family arn arns
  for family in "${TASK_FAMILIES[@]}"; do
    arns=$(aws ecs list-task-definitions --family-prefix "$family" --status ACTIVE \
      --query "taskDefinitionArns[]" --output text --region "$REGION")
    for arn in $arns; do
      # family-prefix は前方一致のため、ファミリー名が完全一致するものだけを対象にする
      if [[ "$arn" == *":task-definition/${family}:"* ]]; then
        aws ecs deregister-task-definition --task-definition "$arn" --region "$REGION" >/dev/null
        info "タスク定義を登録解除しました: $arn"
      fi
    done
  done
}

# ------------------------------------------------------------
# 3. ロググループの削除
# ------------------------------------------------------------
delete_log_groups() {
  local group found
  for group in "${LOG_GROUPS[@]}"; do
    found=$(aws logs describe-log-groups --log-group-name-prefix "$group" \
      --query "logGroups[?logGroupName=='$group'].logGroupName" --output text --region "$REGION")
    if [[ -z "$found" ]]; then
      info "ロググループ $group は存在しません（スキップ）"
      continue
    fi
    aws logs delete-log-group --log-group-name "$group" --region "$REGION"
    info "ロググループを削除しました: $group"
  done
}

# ------------------------------------------------------------
# 4. ECR リポジトリの削除（イメージを含む）
# ------------------------------------------------------------
delete_ecr_repository() {
  if ! aws ecr describe-repositories --repository-names "$ECR_REPOSITORY" --region "$REGION" >/dev/null 2>&1; then
    info "ECR リポジトリ $ECR_REPOSITORY は存在しません（スキップ）"
    return
  fi
  aws ecr delete-repository --repository-name "$ECR_REPOSITORY" --force --region "$REGION" >/dev/null
  info "ECR リポジトリを削除しました: $ECR_REPOSITORY"
}

# ------------------------------------------------------------
# 5. ローカルのコンテナイメージの削除（myweb のイメージのみ）
# ------------------------------------------------------------
delete_local_images() {
  local ids
  if ! command -v docker >/dev/null 2>&1; then
    info "docker コマンドがないため、ローカルイメージの削除をスキップします"
    return
  fi
  # リポジトリ名が myweb、または <レジストリ>/myweb のイメージを対象にする
  ids=$(docker images --format '{{.ID}} {{.Repository}}' \
    | awk -v repo="$ECR_REPOSITORY" '$2 == repo || $2 ~ ("/" repo "$") {print $1}' | sort -u)
  if [[ -z "$ids" ]]; then
    info "ローカルに $ECR_REPOSITORY のイメージはありません（スキップ）"
    return
  fi
  # shellcheck disable=SC2086
  docker rmi -f $ids >/dev/null
  info "ローカルのコンテナイメージを削除しました"
}

delete_stack
deregister_task_definitions
delete_log_groups
delete_ecr_repository
delete_local_images

info "クリーンアップが完了しました"
