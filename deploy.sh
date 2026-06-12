#!/bin/bash

# Configuration
PROJECT="ruoyi-vue-pro" # default
BRANCH="dev"
FORCE_DEPLOY=false
TRIGGER_SOURCE="WebHook"

# 获取北京时间 (TZ=Asia/Shanghai)
get_bj_time() {
    TZ='Asia/Shanghai' date '+%Y-%m-%d %H:%M:%S'
}

while [[ "$#" -gt 0 ]]; do
    case $1 in
        --project) PROJECT="$2"; shift ;;
        --force) FORCE_DEPLOY=true ;;
        --trigger) TRIGGER_SOURCE="$2"; shift ;;
        *) echo "Unknown parameter: $1"; exit 1 ;;
    esac
    shift
done

# 动态检测执行环境，配置自适应目录（支持宿主机与容器内部双向执行）
if [ -d "/home/yeeco/ruoyi-vue-pro" ]; then
    # 宿主机执行路径
    BASE_DIR_BACKEND="/home/yeeco/ruoyi-vue-pro"
    BASE_DIR_FRONTEND="/home/yeeco/yudao-ui-admin-vue3"
    export FRONTEND_BUILD_CONTEXT="../yudao-ui-admin-vue3"
else
    # 容器内部执行路径
    BASE_DIR_BACKEND="/workspace"
    BASE_DIR_FRONTEND="/workspace-frontend"
    export FRONTEND_BUILD_CONTEXT="/workspace-frontend"
fi

if [ "$PROJECT" = "ruoyi-vue-pro" ]; then
    PROJECT_DIR="$BASE_DIR_BACKEND"
    STATUS_FILE="$BASE_DIR_BACKEND/deploy_status_backend.json"
    LOG_FILE="$BASE_DIR_BACKEND/deploy_backend.log"
else
    PROJECT_DIR="$BASE_DIR_FRONTEND"
    STATUS_FILE="$BASE_DIR_BACKEND/deploy_status_frontend.json"
    LOG_FILE="$BASE_DIR_BACKEND/deploy_frontend.log"
fi

COMPOSE_DIR="$BASE_DIR_BACKEND"

# Ensure directories exist
mkdir -p "$PROJECT_DIR"
cd "$PROJECT_DIR" || exit 1

# Redirect stdout/stderr to log file
exec > >(tee "$LOG_FILE") 2>&1

update_status() {
    local status="$1"
    local message="$2"
    local start_time="$3"
    local end_time="$4"
    local trigger="$5"
    
    local commit_hash=$(git rev-parse HEAD 2>/dev/null || echo "unknown")
    local commit_msg=$(git log -1 --pretty=%B 2>/dev/null | tr -d '"\n\r' || echo "unknown")
    local commit_author=$(git log -1 --pretty=%an 2>/dev/null || echo "unknown")
    
    cat <<EOF > "$STATUS_FILE"
{
  "project": "$PROJECT",
  "status": "$status",
  "message": "$message",
  "start_time": "$start_time",
  "end_time": "$end_time",
  "trigger": "$trigger",
  "commit_hash": "$commit_hash",
  "commit_msg": "$commit_msg",
  "commit_author": "$commit_author"
}
EOF
}

# 1. Fetch remote branch
echo "=========================================="
echo "Deployment Started: $(get_bj_time)"
echo "Project: $PROJECT"
echo "Trigger: $TRIGGER_SOURCE"
echo "=========================================="

echo "Fetching origin $BRANCH..."
git fetch origin "$BRANCH"

LOCAL_HASH=$(git rev-parse HEAD 2>/dev/null || echo "local-empty")
REMOTE_HASH=$(git rev-parse origin/"$BRANCH" 2>/dev/null || echo "remote-empty")

if [ "$LOCAL_HASH" = "$REMOTE_HASH" ] && [ "$FORCE_DEPLOY" = "false" ]; then
    echo "No code changes detected. Skipping deployment."
    echo "无更新代码，跳过部署"
    update_status "SUCCESS" "No code changes detected. Deployment is up to date." "$(get_bj_time)" "$(get_bj_time)" "$TRIGGER_SOURCE"
    exit 0
fi

START_TIME=$(get_bj_time)
update_status "DEPLOYING" "Code changes detected, starting deployment..." "$START_TIME" "" "$TRIGGER_SOURCE"

# 2. Pull code
echo "Pulling latest code..."
git pull origin "$BRANCH"
if [ $? -ne 0 ]; then
    echo "Error: Git pull failed"
    update_status "FAILED" "Git pull failed" "$START_TIME" "$(get_bj_time)" "$TRIGGER_SOURCE"
    exit 1
fi

# Detect Docker Compose command
if docker compose version >/dev/null 2>&1; then
    DOCKER_COMPOSE="docker compose"
else
    DOCKER_COMPOSE="docker-compose"
fi

# 3. Project specific build and deploy
if [ "$PROJECT" = "ruoyi-vue-pro" ]; then
    echo "Compiling Java Backend project with Maven..."
    docker run --rm \
      -v "/home/yeeco/ruoyi-vue-pro":/app \
      -v maven_cache:/root/.m2 \
      -w /app \
      maven:3.8.5-openjdk-8 \
      mvn clean package -DskipTests
      
    if [ $? -ne 0 ]; then
        echo "Error: Maven compilation failed"
        update_status "FAILED" "Maven compilation failed" "$START_TIME" "$(get_bj_time)" "$TRIGGER_SOURCE"
        exit 1
    fi
    
    echo "Starting Backend and Redis services..."
    cd "$COMPOSE_DIR" || exit 1
    $DOCKER_COMPOSE -p ruoyi-vue-pro up -d --build server redis
else
    echo "Starting Frontend service (build runs inside container)..."
    cd "$COMPOSE_DIR" || exit 1
    $DOCKER_COMPOSE -p ruoyi-vue-pro up -d --build admin
fi

if [ $? -ne 0 ]; then
    echo "Error: Container startup failed"
    update_status "FAILED" "Docker container build/startup failed" "$START_TIME" "$(get_bj_time)" "$TRIGGER_SOURCE"
    exit 1
fi

echo "Cleaning up dangling images..."
docker image prune -f

echo "=========================================="
echo "Deployment Succeeded: $(get_bj_time)"
echo "=========================================="

update_status "SUCCESS" "Deployment completed successfully" "$START_TIME" "$(get_bj_time)" "$TRIGGER_SOURCE"
