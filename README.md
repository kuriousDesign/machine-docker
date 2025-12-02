git clone [<repo-url>](https://github.com/kuriousDesign/machine-docker.git) machine-docker
cd machine-docker

# GET LATEST CODE
git submodule foreach 'git fetch && git checkout master && git pull origin master'


# RUN ONE SERVICE
docker compose up -d <service-name>
