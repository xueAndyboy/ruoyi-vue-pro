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

# 配置 git 超时限制（15秒连不上或30秒内速度低于1KB/s则断开）
git config http.connectTimeout 15
git config http.lowSpeedLimit 1000
git config http.lowSpeedTime 30

echo "Fetching origin $BRANCH..."
git fetch origin "$BRANCH"
FETCH_RES=$?

if [ $FETCH_RES -ne 0 ]; then
    echo "[警告] 直连 GitHub 官方源超时或失败，正在尝试通过国内加速代理源（ghproxy.cn）重新获取..."
    
    # 备份原 URL
    ORIGIN_URL=$(git remote get-url origin)
    # 构造代理 URL
    PROXY_URL=$(echo "$ORIGIN_URL" | sed 's|https://github.com|https://ghproxy.cn/https://github.com|g')
    
    echo "临时切换源至: $PROXY_URL"
    git remote set-url origin "$PROXY_URL"
    
    # 忽略 SSL 证书错误（代理源证书常见问题）
    git -c http.sslVerify=false fetch origin "$BRANCH"
    FETCH_RES=$?
    
    # 无论成功与否，必须还原官方源地址，防止污染本地 Git 配置
    git remote set-url origin "$ORIGIN_URL"
fi

if [ $FETCH_RES -ne 0 ]; then
    echo "[错误] Git fetch 失败（官方源和代理镜像源均不可达，请检查网络）"
    exit 1
fi

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

# 2. Reset and align code (强制本地对齐，丢弃未跟踪修改，不二次联网)
echo "Aligning code to origin/$BRANCH..."
git reset --hard origin/"$BRANCH"
if [ $? -ne 0 ]; then
    echo "Error: Git reset failed"
    update_status "FAILED" "Git reset --hard failed" "$START_TIME" "$(get_bj_time)" "$TRIGGER_SOURCE"
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
