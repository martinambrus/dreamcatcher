# Install on Ubuntu
- `sudo apt update`
- (optional) `sudo apt upgrade -y` (and then possibly `sudo reboot`)
- `sudo apt install curl`
- `curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash - && sudo apt-get install -y nodejs`
- `sudo apt-get update && sudo apt-get install ca-certificates curl gnupg -y`
- `sudo install -m 0755 -d /etc/apt/keyrings && curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg && sudo chmod a+r /etc/apt/keyrings/docker.gpg`
- `echo "deb [arch="$(dpkg --print-architecture)" signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu "$(. /etc/os-release && echo "$VERSION_CODENAME")" stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null`
- `sudo apt-get update && sudo apt-get install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin -y`
- `git clone https://github.com/martinambrus/dreamcatcher.git && cd dreamcatcher`
- `for filename in ./infrastructure/postgre/credentials/*; do mv "./$filename" "./$(echo "$filename" | sed -e 's/_example//g')"; done`
- `shopt -s nullglob && shopt -s globstar && shopt -s dotglob && for fname in **/*.example ; do mv -- "${fname}" "${fname%.example}"; done`
- `sudo chmod +x *.sh && sudo ./start_docker.sh`

... then, once Kafka containers start restarting (because of wrong permissions), execute the following: `cd infrastructure/datadir && chmod 777 kafka_0_data kafka_1_data kafka_2_data`