# homebrew install (linux & macos):
NONINTERACTIVE=1 \
/bin/bash -c \
"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# linux brew environment:
eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"

# linux & macos (brew):
brew install -y git gh

# termux:
pkg update && pkg install -y git gh

# debian based:
sudo apt update && sudo apt install -y git gh
