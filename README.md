git clone [<repo-url>](https://github.com/kuriousDesign/machine-docker.git) machine-docker
cd machine-docker

# GET LATEST CODE
git submodule foreach 'git fetch && git checkout master && git pull origin master'


# RUN ONE SERVICE
docker compose up -d <service-name>


# REMOTE IPC
192.168.70.12
hostname: APO-IPC-00251-01
user: apollo-admin

## copy cert to remote ssh on windows
type $env:USERPROFILE\.ssh\id_rsa.pub | ssh apollo-admin@192.168.70.1 "mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys"
