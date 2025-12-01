git clone [<repo-url>](https://github.com/kuriousDesign/machine-docker.git) machine-docker
cd machine-docker

git submodule foreach 'git fetch && git checkout master && git pull origin master'
