make clean && make stage                                   
mkdir -p Payload                                                        
cp -r .theos/_/Applications/EZCompleteUI.app Payload/                    
zip -r9 EZCompleteUI.ipa Payload
rm -rf Payload                              