#pragma once
#include "prefix_cache.h"
#include "nlohmann/json.hpp"
#include <array>

// Accept exactly Python json.dumps(..., ensure_ascii=False)'s student contract.
// Parsing determines field identity; exact reserialization rejects duplicates,
// alternate key order, injected trailing objects, and noncanonical encodings.
struct StudentSentinels {
    bool eligible = false;
    std::string first, second, metadata, reason = "unsupported_student_json";
};
inline std::string student_quote(const std::string & s) {
    return nlohmann::json(s).dump(-1,' ',false,nlohmann::json::error_handler_t::strict);
}
inline StudentSentinels student_sentinels(const std::string & input) {
    using ordered = nlohmann::ordered_json;
    StudentSentinels result;
    try {
        const auto value = ordered::parse(input);
        const std::array<std::string,6> keys{"mode","language","romanize","instructions","vocabulary","transcript"};
        if(!value.is_object() || value.size()!=keys.size())return result;
        size_t index=0;
        for(auto it=value.begin();it!=value.end();++it)
            if(it.key()!=keys[index++])return result;
        for(auto key:{"mode","language","instructions","transcript"})
            if(!value.at(key).is_string())return result;
        if(!value.at("romanize").is_boolean() || !value.at("vocabulary").is_array())return result;
        const std::string mode=value.at("mode").get<std::string>();
        if(mode!="default" && mode!="message" && mode!="email" && mode!="note" && mode!="code" && mode!="terminal")return result;
        if(value.at("language").get<std::string>().empty())return result;
        // Production appends prior transcript context inside instructions for
        // split requests. Such instructions are not immutable metadata.
        if(value.at("instructions").get<std::string>().find("Previous text (context only")!=std::string::npos){
            result.reason="previous_piece_context_not_cacheable";return result;
        }
        std::string vocabulary="[";
        for(const auto & term:value.at("vocabulary")){
            if(!term.is_string())return result;
            if(vocabulary.size()>1)vocabulary+=", ";
            vocabulary+=student_quote(term.get<std::string>());
        }
        vocabulary+="]";
        std::string header="{\"mode\": "+student_quote(mode)+", \"language\": "+student_quote(value.at("language").get<std::string>())+
            ", \"romanize\": "+std::string(value.at("romanize").get<bool>()?"true":"false")+
            ", \"instructions\": "+student_quote(value.at("instructions").get<std::string>())+
            ", \"vocabulary\": "+vocabulary+", \"transcript\": ";
        if(header+student_quote(value.at("transcript").get<std::string>())+"}"!=input){
            result.reason="noncanonical_student_json";return result;
        }
        // Only metadata reaches either sentinel prompt. The parsed transcript
        // is used solely for canonical-input validation, never for construction.
        result.eligible=true;result.metadata=header;
        result.first=header+student_quote("A")+"}";
        result.second=header+student_quote("中")+"}";
        result.reason="eligible";
    }catch(const nlohmann::json::exception &){return result;}
    return result;
}
inline std::vector<int32_t> aligned_student_prefix(
    const std::vector<int32_t> & system,const std::vector<int32_t> & first,
    const std::vector<int32_t> & second,const std::vector<int32_t> & actual,
    size_t batch,size_t cap=1024) {
    if(!batch || !prefix_matches(system,actual))return {};
    auto header=static_prefix(first,second);
    if(!prefix_matches(system,header) || system.size()>=cap)return {};
    size_t available=std::min(header.size(),cap);
    size_t end=system.size()+((available-system.size())/batch)*batch;
    if(end<=system.size())return {};
    header.resize(end);
    // Exact real prompt prefix is mandatory, independent of the parser check.
    if(!prefix_matches(header,actual))return {};
    return header;
}
