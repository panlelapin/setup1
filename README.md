```sh
  # brew (fedora & macos):
  NONINTERACTIVE=1 \
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
```
```sh
  # fedora & macos (brew):
  HOMEBREW_NO_ASK=1 \
  HOMEBREW_NO_AUTO_UPDATE=1 \
  sudo apt update && sudo apt install git gh
```
```sh
  # termux:
  pkg update && pkg install -y git gh
```
```sh
  # debians:
  sudo apt update && sudo apt install -y git gh
```
