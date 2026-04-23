def buildNodeService(serviceName) {
    dir(serviceName) {
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

pipeline {
    agent { label 'agent-127' }

    options {
        skipDefaultCheckout(true)
    }

    parameters {
        string(
            name: 'VERSION',
            defaultValue: '1.0.0',
            description: 'Enter release version'
        )
    }

    environment {
        CYB_MF_HOST_IP = '192.168.0.127'
        VERSION = "${params.VERSION}"
    }

    stages {

        stage('Checkout') {
            tools { nodejs 'NodeJS_24.5.0' }
            steps {
                checkout scm
                echo "Building branch: ${env.BRANCH_NAME}"
                echo "Target Host: ${env.CYB_MF_HOST_IP}"
            }
        }

        stage('Build Services') {
            tools { nodejs 'NodeJS_24.5.0' }
            steps {
                script {
                    // Base services list
                    def baseServices = ["shared-lib","root-config","root-container","tb-cybersio-ui","tb-thirdParty-ui","tb-rbac"]

                    // build shared-lib first
                    buildNodeService('shared-lib')

                    // then build the rest in parallel
                    def parallelBuilds = [:]
                    for (svc in baseServices - ["shared-lib"]) {
                        def service = svc
                        parallelBuilds[service] = { buildNodeService(service) }
                    }
                    parallel parallelBuilds
                }
            }
        }

        stage('Artifact Generation') {
            steps {
                script {
                    def versionFolder = "/opt/Artifact-Generation/base-microfrontend-${params.VERSION}"
                    def services = ["shared-lib","root-config","root-container","tb-cybersio-ui","tb-thirdParty-ui","tb-rbac"]

                    sh """
                        # Force delete using docker (handles root-owned files)
                        if [ -d "${versionFolder}" ]; then
                            echo "Force deleting ${versionFolder} using docker..."
                            docker run --rm -v ${versionFolder}:/data alpine sh -c "rm -rf /data/*"
                        fi
                    
                        rm -rf ${versionFolder}
                        mkdir -p ${versionFolder}
                    
                        echo "Copying artifacts..."
                        for svc in ${services.join(" ")}; do
                            if [ -d "\$svc/dist" ]; then
                                mkdir -p ${versionFolder}/\$svc
                                cp -r \$svc/dist ${versionFolder}/\$svc/
                                cp \$svc/Dockerfile ${versionFolder}/\$svc/ 2>/dev/null || true
                                cp \$svc/*.sh ${versionFolder}/\$svc/ 2>/dev/null || true
                            else
                                echo "ERROR: \$svc/dist not found!"
                                exit 1
                            fi
                        done
                    
                        echo "Extracting root-config JSON files..."
                        for file in microfrontends.json config.json; do
                            if [ -f "root-config/dist/\$file" ]; then
                                cp root-config/dist/\$file ${versionFolder}/
                            fi
                        done
                    """
                }
            }
        }

        stage('Certificates Generation') {
            steps {
                script {
                    def versionFolder = "/opt/Artifact-Generation/base-microfrontend-${params.VERSION}"
                    def services = ["shared-lib","root-config","root-container","tb-cybersio-ui","tb-thirdParty-ui","tb-rbac"]

                    sh """
                        generate_cert() {
                            service=\$1
                            dir=${versionFolder}/\$service

                            if [ -d "\$dir" ]; then
                                cd \$dir
                                if [ ! -f certificate.pem ] || [ ! -f key.pem ]; then
                                    echo "Generating certificate for \$service"

                                    openssl req -x509 -nodes -days 365 \
                                    -newkey rsa:2048 \
                                    -keyout key.pem \
                                    -out certificate.pem \
                                    -subj "/C=IN/ST=TN/L=Chennai/O=Cybersio/OU=DevOps/CN=localhost"
                                fi
                            fi
                        }

                        for svc in ${services.join(" ")}; do
                            generate_cert \$svc
                        done
                    """
                }
            }
        }

        stage('Docker Build') {
            steps {
                script {
                    def versionFolder = "/opt/Artifact-Generation/base-microfrontend-${params.VERSION}"

                    sh """
                        cd ${versionFolder}
                        echo "Building Docker images..."
                        DOCKER_BUILDKIT=0 CYB_MF_HOST_IP=${env.CYB_MF_HOST_IP} VERSION=${params.VERSION} \
                        docker compose -f docker-compose-files/docker-compose-base.yaml build
                    """
                }
            }
        }

        stage('Export Docker Image') {
            steps {
                script {
                    def versionFolder = "/opt/Artifact-Generation/base-microfrontend-${params.VERSION}"
                    def services = ["shared-lib","root-config","root-container","tb-cybersio-ui","tb-thirdParty-ui","tb-rbac"]
        
                    for (svc in services) {
                        def imageName = "cybersio/${svc.toLowerCase()}:${params.VERSION}"
                        def tarFile = "${versionFolder}/${svc.toLowerCase()}-${params.VERSION}.tar.gz"
        
                        sh """
                            if docker image inspect ${imageName} > /dev/null 2>&1; then
                                docker save ${imageName} | gzip > ${tarFile}
                            else
                                echo "Image not found: ${imageName}"
                            fi
                        """
                    }
                }
            }
        }
    }

    post {
        always {
            cleanWs()
        }
    }
}
