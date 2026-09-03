```
curl -fsSL https://raw.githubusercontent.com/panlelapin/setup1/master/setup1.sh|bash
```






install
```sh
# linux & macos (brew):
NONINTERACTIVE=1 /bin/bash -c \
"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" && \
export PATH="/opt/homebrew/bin:/home/linuxbrew/.linuxbrew/bin:/usr/local/bin:$PATH" && \
eval "$(brew shellenv)" && brew install -y git gh
```
or
```sh
# termux:
pkg update && pkg install -y git gh
```
or
```sh
# debian based:
sudo apt update && sudo apt install -y git gh
```
then
```sh
# gh & git setup (needs web)
gh auth login --web && gh auth setup-git && \
git config --global user.name "$(gh api user --jq '.name // .login')" && \
git config --global user.email \
"$(gh api user --jq '"\(.id)+\(.login)@users.noreply.github.com"')"
```
and
```sh
# hand over to private repo
export pd="$HOME/p" && mkdir -p "$pd" && gh repo clone setup "$pd/setup2" && \
bash "$pd/setup2/setup2.sh"
```
