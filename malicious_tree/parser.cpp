#include <string>
#include <cstdint>
#include <cstddef>
int parse_input(const uint8_t* d, size_t n){int a=0;for(size_t i=0;i<n;i++)a+=d[i];return a;}
bool check_name(const std::string& s){return s.size()>3 && s[0]=='A';}
