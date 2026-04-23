def buildFrontendService(serviceName) {
    dir("Frontend/${serviceName}") {
        sh '''
            set -e

            if [ -f package-lock.json ]; then
                echo "Using npm ci"
                npm ci --legacy-peer-deps --no-audit --no-fund
            else
                echo "No lockfile, using npm install"
                npm install --legacy-peer-deps --no-audit --no-fund
            fi

            npm run build:webpack
        '''
    }
}

def buildBackendService(serviceName, useExtraPackages = false) {
    dir("Backend/${serviceName}") {
        sh """
            set -e
            npm ci --legacy-peer-deps --no-audit --no-fund
            
            ${useExtraPackages ? '''
            npm install copy-webpack-plugin
            npm install webpack-node-externals
            npm install babel-loader @babel/core @babel/preset-env --save-dev
            ''' : ''}
            
            npm run build
        """
    }
}

pipeline {
    agent { label 'agent-127' }
    
    options {
        skipDefaultCheckout(true)
        timestamps()
        timeout(time: 2, unit: 'HOURS')
    }
    
    parameters {
        string(
            name: 'VERSION',
            defaultValue: '2.2.17',
            description: 'Enter release version (matches docker-compose version)'
        )
        
        string(
            name: 'CYB_MF_HOST_IP',
            defaultValue: '192.168.0.127',
            description: 'Frontend Host IP'
        )
    }
    
    environment {
        // Frontend
        FRONTEND_WORKSPACE = "/home/jenkins/workspace/tb-CyberSIO/Frontend"
        FRONTEND_SERVICES = "shared-lib,root-config,root-container,tb-cybersio-ui,tb-thirdParty-ui,tb-rbac"
        
        // Backend
        BACKEND_WORKSPACE = "/home/jenkins/workspace/tb-CyberSIO/Backend"
        BACKEND_SERVICES = "dist-api-gateway,tb-rbac-backend"
        
        // Combined
        VERSION = "${params.VERSION}"
        CYB_MF_HOST_IP = "${params.CYB_MF_HOST_IP}"
    }
    
    stages {
        stage('Checkout All Repositories') {
            tools { nodejs 'NodeJS_24.5.0' }
            steps {
                script {
                    // Checkout frontend
                    dir('frontend') {
                        checkout scm
                        echo "Building frontend branch: ${env.BRANCH_NAME}"
                    }
                    
                    // Checkout backend services
                    dir('backend/dist-api-gateway') {
                        checkout scm
                    }
                    
                    dir('backend/tb-rbac-backend') {
                        checkout scm
                    }
                }
            }
        }
        
        stage('Load Backend Environment Variables') {
            steps {
                withCredentials([file(credentialsId: 'cybersio-env', variable: 'ENV_FILE')]) {
                    sh '''
                        echo "Loading backend environment variables..."
                        mkdir -p backend
                        cp $ENV_FILE backend/.env
                        echo "Variables detected:"
                        grep -v '^#' backend/.env | cut -d '=' -f1 | head -20
                    '''
                }
            }
        }
        
        stage('Build All Services') {
            tools { nodejs 'NodeJS_24.5.0' }
            steps {
                script {
                    // First build shared-lib (dependency for other frontend services)
                    echo "Building shared-lib first..."
                    buildFrontendService('shared-lib')
                    
                    // Build remaining frontend services in parallel
                    def otherFrontendServices = ["root-config","root-container","tb-cybersio-ui","tb-thirdParty-ui","tb-rbac"]
                    def parallelBuilds = [:]
                    
                    for (svc in otherFrontendServices) {
                        def service = svc
                        parallelBuilds[service] = { buildFrontendService(service) }
                    }
                    
                    // Add backend services to parallel builds
                    parallelBuilds['dist-api-gateway'] = { buildBackendService('dist-api-gateway', false) }
                    parallelBuilds['tb-rbac-backend'] = { buildBackendService('tb-rbac-backend', true) }
                    
                    echo "Building all remaining services in parallel..."
                    parallel parallelBuilds
                }
            }
        }
        
        stage('Prepare Artifacts & Certificates') {
            steps {
                script {
                    def frontendServicesList = ["shared-lib","root-config","root-container","tb-cybersio-ui","tb-thirdParty-ui","tb-rbac"]
                    
                    // Frontend artifacts
                    sh """
                        set -e
                        
                        # Force clean frontend directory using docker (handles root-owned files)
                        if [ -d "${env.FRONTEND_WORKSPACE}" ]; then
                            echo "Force deleting ${env.FRONTEND_WORKSPACE} using docker..."
                            docker run --rm -v ${env.FRONTEND_WORKSPACE}:/data alpine sh -c "rm -rf /data/*"
                        fi
                        
                        rm -rf ${env.FRONTEND_WORKSPACE}
                        mkdir -p ${env.FRONTEND_WORKSPACE}
                        
                        # Copy frontend artifacts from workspace
                        cd frontend
                        for svc in ${frontendServicesList.join(" ")}; do
                            if [ -d "\$svc/dist" ]; then
                                mkdir -p ${env.FRONTEND_WORKSPACE}/\$svc
                                cp -r \$svc/dist ${env.FRONTEND_WORKSPACE}/\$svc/
                                cp \$svc/Dockerfile ${env.FRONTEND_WORKSPACE}/\$svc/ 2>/dev/null || true
                                cp \$svc/*.sh ${env.FRONTEND_WORKSPACE}/\$svc/ 2>/dev/null || true
                            else
                                echo "ERROR: \$svc/dist not found!"
                                exit 1
                            fi
                        done
                        
                        # Copy root-config JSON files
                        for file in microfrontends.json config.json; do
                            if [ -f "root-config/dist/\$file" ]; then
                                cp root-config/dist/\$file ${env.FRONTEND_WORKSPACE}/
                            fi
                        done
                        
                        # Generate SSL certificates for each frontend service
                        cd ${env.FRONTEND_WORKSPACE}
                        for svc in ${frontendServicesList.join(" ")}; do
                            if [ -d "\$svc" ]; then
                                cd \$svc
                                if [ ! -f certificate.pem ] || [ ! -f key.pem ]; then
                                    echo "Generating certificate for \$svc"
                                    openssl req -x509 -nodes -days 365 \\
                                    -newkey rsa:2048 \\
                                    -keyout key.pem \\
                                    -out certificate.pem \\
                                    -subj "/C=IN/ST=TN/L=Chennai/O=Cybersio/OU=DevOps/CN=localhost"
                                fi
                                cd ..
                            fi
                        done
                        
                        echo "Frontend artifacts prepared successfully"
                    """
                    
                    // Backend artifacts
                    def backendConfigs = [
                        [name: 'dist-api-gateway', pipeline: 'cybersio-microservice-dist-api'],
                        [name: 'tb-rbac-backend', pipeline: 'cybersio-microservice-rbac']
                    ]
                    
                    for (backend in backendConfigs) {
                        def service = backend.name
                        def pipelineName = backend.pipeline
                        def versionFolder = "${env.BACKEND_WORKSPACE}/${pipelineName}-${params.VERSION}"
                        
                        sh """
                            set -e
                            
                            # Create artifact directory
                            echo "Preparing artifacts for ${service}..."
                            rm -rf ${versionFolder}
                            mkdir -p ${versionFolder}
                            
                            # Copy artifacts from workspace
                            cp -r backend/${service}/dist ${versionFolder}/
                            cp backend/${service}/Dockerfile ${versionFolder}/ 2>/dev/null || true
                            
                            # Copy docker-compose if exists
                            if [ -f "backend/${service}/docker-compose.yaml" ]; then
                                cp backend/${service}/docker-compose.yaml ${versionFolder}/
                            fi
                            
                            # Copy environment file
                            cp backend/.env ${versionFolder}/.env
                            
                            # Validate artifacts
                            if [ ! -d "${versionFolder}/dist" ]; then
                                echo "ERROR: dist not found for ${service}!"
                                exit 1
                            fi
                            
                            # Generate SSL certificates for backend
                            cd ${versionFolder}
                            if [ ! -f certificate.pem ] || [ ! -f key.pem ]; then
                                echo "Generating certificate for ${service}"
                                openssl req -x509 -nodes -days 365 \\
                                -newkey rsa:2048 \\
                                -keyout key.pem \\
                                -out certificate.pem \\
                                -subj "/C=IN/ST=TN/L=Chennai/O=Cybersio/OU=DevOps/CN=localhost"
                            fi
                            
                            echo "${service} artifacts prepared successfully at ${versionFolder}"
                        """
                    }
                }
            }
        }
        
        stage('Docker Build All Services') {
            steps {
                script {
                    // Copy combined docker-compose.yaml to workspace
                    sh """
                        # Check if docker-compose.yaml exists in current directory
                        if [ -f "docker-compose.yaml" ]; then
                            cp docker-compose.yaml ${env.FRONTEND_WORKSPACE}/docker-compose.yaml
                            echo "Combined docker-compose.yaml copied to frontend workspace"
                        else
                            echo "ERROR: docker-compose.yaml not found!"
                            echo "Please ensure docker-compose.yaml is in the workspace root"
                            exit 1
                        fi
                    """
                    
                    // Build all containers using combined compose file
                    sh """
                        cd ${env.FRONTEND_WORKSPACE}
                        echo "========================================="
                        echo "Building all Docker images"
                        echo "========================================="
                        echo "Version: ${params.VERSION}"
                        echo "Host IP: ${env.CYB_MF_HOST_IP}"
                        echo "Working directory: \$(pwd)"
                        echo ""
                        echo "Docker images to be built:"
                        echo "  - shared-lib:${params.VERSION}"
                        echo "  - root-config:${params.VERSION}"
                        echo "  - root-container:${params.VERSION}"
                        echo "  - tb-cybersio-ui:${params.VERSION}"
                        echo "  - tb-thirdparty-ui:${params.VERSION}"
                        echo "  - tb-rbac:${params.VERSION}"
                        echo "  - dist-api-gateway:${params.VERSION}"
                        echo "  - tb-rbac-backend:${params.VERSION}"
                        echo ""
                        
                        DOCKER_BUILDKIT=0 CYB_MF_HOST_IP=${env.CYB_MF_HOST_IP} VERSION=${params.VERSION} \\
                        docker compose -f docker-compose.yaml build --parallel
                        
                        echo ""
                        echo "========================================="
                        echo "Docker images built successfully"
                        echo "========================================="
                        docker images | grep "cybersio" | grep "${params.VERSION}"
                    """
                }
            }
        }
        
        stage('Deployment Ready') {
            steps {
                echo """
                    ========================================
                    BUILD COMPLETED SUCCESSFULLY
                    ========================================
                    Version: ${params.VERSION}
                    Host: 192.168.0.127 (agent-127)
                    
                    Frontend Artifacts: ${env.FRONTEND_WORKSPACE}
                    Backend Artifacts: ${env.BACKEND_WORKSPACE}
                    
                    Services Built:
                    ✓ shared-lib:${params.VERSION}
                    ✓ root-config:${params.VERSION}
                    ✓ root-container:${params.VERSION}
                    ✓ tb-cybersio-ui:${params.VERSION}
                    ✓ tb-thirdParty-ui:${params.VERSION}
                    ✓ tb-rbac:${params.VERSION}
                    ✓ dist-api-gateway:${params.VERSION}
                    ✓ tb-rbac-backend:${params.VERSION}
                    
                    To deploy:
                    cd ${env.FRONTEND_WORKSPACE}
                    docker compose -f docker-compose.yaml up -d
                    
                    To check status:
                    docker compose -f docker-compose.yaml ps
                    
                    To view logs:
                    docker compose -f docker-compose.yaml logs -f
                    ========================================
                """
            }
        }
    }
    
    post {
        success {
            echo """
                🎉 SUCCESS: Pipeline completed for version ${params.VERSION}
                📍 All services built on agent-127 (192.168.0.127)
            """
        }
        failure {
            echo """
                ❌ FAILURE: Pipeline failed for version ${params.VERSION}
                Please check the logs above for details.
            """
        }
        always {
            cleanWs()
        }
    }
}
