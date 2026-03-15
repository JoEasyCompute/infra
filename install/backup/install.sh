#!/bin/bash
# Move all install scripts to home directory
mv ~/infra/gpucheck/*.sh ~
mv ~/infra/IPMI* ~
mv ~/infra/drivers/Intel ~
mv ~/infra/install/*.sh ~
mv ~/infra/.bashrc ~
mv ~/infra/.aliases ~
ln -s ~/.aliases ~/.bash_aliases
source ~/.bashrc
