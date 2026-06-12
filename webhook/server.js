const express = require('express');
const { spawn, exec } = require('child_process');
const fs = require('fs');
const path = require('path');

const app = express();
const PORT = process.env.PORT || 9000;
const PROJECT_PATH = process.env.PROJECT_PATH || '/workspace';
const PROJECT_PATH_FRONTEND = process.env.PROJECT_PATH_FRONTEND || '/workspace-frontend';

// 检测挂载是否就绪（避免 WSL2 启动延迟导致的空挂载问题）
const deployShPath = path.join(PROJECT_PATH, 'deploy.sh');
if (!fs.existsSync(deployShPath)) {
    console.error(`[Webhook 启动失败] 未在 ${PROJECT_PATH} 找到 deploy.sh。`);
    console.error(`这通常是由于 WSL2/Docker 启动时宿主机目录尚未完成挂载导致的。`);
    console.error(`容器将在 5 秒后退出并由 Docker 自动重启尝试重新挂载...`);
    setTimeout(() => {
        process.exit(1);
    }, 5000);
} else {
    console.log(`[Webhook 启动成功] 挂载验证通过，找到部署脚本: ${deployShPath}`);
}

app.use(express.json());
app.use(express.urlencoded({ extended: true }));

// Store active processes
let activeProcesses = {
    'ruoyi-vue-pro': null,
    'yudao-ui-admin-vue3': null
};

// Serve HTML dashboard
app.get('/hooks/status', (req, res) => {
    res.sendFile(path.join(__dirname, 'views', 'status.html'));
});

// Fetch both backend and frontend status
app.get('/hooks/api/status', (req, res) => {
    const backendStatusFile = path.join(PROJECT_PATH, 'deploy_status_backend.json');
    const frontendStatusFile = path.join(PROJECT_PATH, 'deploy_status_frontend.json');
    
    let backendStatus = { status: 'IDLE', message: 'No deployment history' };
    let frontendStatus = { status: 'IDLE', message: 'No deployment history' };
    
    if (fs.existsSync(backendStatusFile)) {
        try { backendStatus = JSON.parse(fs.readFileSync(backendStatusFile, 'utf8')); } catch (e) {}
    }
    if (fs.existsSync(frontendStatusFile)) {
        try { frontendStatus = JSON.parse(fs.readFileSync(frontendStatusFile, 'utf8')); } catch (e) {}
    }
    
    res.json({
        backend: backendStatus,
        frontend: frontendStatus
    });
});

// Fetch raw logs for specific project
app.get('/hooks/api/logs', (req, res) => {
    const project = req.query.project || 'ruoyi-vue-pro';
    const logFile = project === 'ruoyi-vue-pro'
        ? path.join(PROJECT_PATH, 'deploy_backend.log')
        : path.join(PROJECT_PATH, 'deploy_frontend.log');
        
    if (fs.existsSync(logFile)) {
        try {
            const logs = fs.readFileSync(logFile, 'utf8');
            return res.type('text/plain').send(logs);
        } catch (e) {
            return res.status(500).send('Failed to read log file');
        }
    }
    return res.type('text/plain').send(`No logs found for ${project}.`);
});

// Trigger deployment helper
function triggerDeployment(project, triggerSource, force = false) {
    if (activeProcesses[project]) {
        console.log(`Deployment for ${project} already in progress. Ignoring.`);
        return false;
    }

    const scriptPath = path.join(PROJECT_PATH, 'deploy.sh');
    const args = ['--project', project, '--trigger', triggerSource];
    if (force) {
        args.push('--force');
    }

    console.log(`Starting deploy script for ${project}: ${scriptPath} ${args.join(' ')}`);
    
    activeProcesses[project] = spawn('bash', [scriptPath, ...args], {
        cwd: PROJECT_PATH,
        env: { ...process.env, PATH: process.env.PATH + ':/usr/local/bin:/usr/bin:/bin' }
    });

    activeProcesses[project].stdout.on('data', (data) => {
        console.log(`[${project} stdout]: ${data}`);
    });

    activeProcesses[project].stderr.on('data', (data) => {
        console.error(`[${project} stderr]: ${data}`);
    });

    activeProcesses[project].on('close', (code) => {
        console.log(`[${project}] Deploy script closed with exit code ${code}`);
        activeProcesses[project] = null;
    });

    return true;
}

// GET Manual deployment endpoint
app.get('/hooks/deploy', (req, res) => {
    const { project, branch, force } = req.query;

    if ((project !== 'ruoyi-vue-pro' && project !== 'yudao-ui-admin-vue3') || branch !== 'dev') {
        return res.status(400).send('参数不正确。支持 project=ruoyi-vue-pro 或 yudao-ui-admin-vue3，且 branch=dev');
    }

    if (activeProcesses[project]) {
        return res.send(`项目 ${project} 正在部署中，请勿重复触发！`);
    }

    const isForce = force === 'true';

    // 异步启动部署流程，立刻返回响应，避免 Nginx 504 挂起超时
    const triggered = triggerDeployment(project, 'Manual GET Interface', isForce);
    if (triggered) {
        return res.send(`已在后台成功启动项目 ${project} 的部署流程！请返回状态页面实时查看日志和进度。`);
    } else {
        return res.status(500).send('部署启动失败，请检查 Webhook 控制台服务日志。');
    }
});

// POST Webhook endpoint
app.post('/hooks/github', (req, res) => {
    const payload = req.body;
    
    if (payload.ref === 'refs/heads/dev') {
        const repoUrl = payload.repository.html_url;
        let project = "";
        
        if (repoUrl.includes('ruoyi-vue-pro')) {
            project = 'ruoyi-vue-pro';
        } else if (repoUrl.includes('yudao-ui-admin-vue3')) {
            project = 'yudao-ui-admin-vue3';
        }
        
        if (project) {
            console.log(`Received GitHub push webhook for ${project}.`);
            const triggered = triggerDeployment(project, 'GitHub Webhook', false);
            if (triggered) {
                return res.json({ message: `Webhook received, starting deployment for ${project}` });
            } else {
                return res.status(500).json({ message: `Failed to start deployment for ${project}` });
            }
        }
    }

    return res.json({ message: 'Ignored.' });
});

app.listen(PORT, '0.0.0.0', () => {
    console.log(`WebHook Server running on http://0.0.0.0:${PORT}`);
});
