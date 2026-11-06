#pragma once
#include <algorithm>
#include <cstdint>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

struct PrefixIdentity {
    std::string model, chat_template, context, system;
    bool operator==(const PrefixIdentity & other) const {
        return model==other.model && chat_template==other.chat_template && context==other.context && system==other.system;
    }
};
// Pure policy: no actual transcript tokens influence the candidate prefix.
inline std::vector<int32_t> static_prefix(const std::vector<int32_t> & first,
                                        const std::vector<int32_t> & second) {
    size_t n=0;while(n<first.size() && n<second.size() && first[n]==second[n])++n;
    // State serialization does not include logits. Always replay one static
    // token and the remaining user suffix before requesting any logits.
    if(n<2)return {};
    return {first.begin(),first.begin()+n-1};
}
inline bool prefix_matches(const std::vector<int32_t> & prefix,const std::vector<int32_t> & input) {
    return !prefix.empty() && prefix.size()<input.size() && std::equal(prefix.begin(),prefix.end(),input.begin());
}
struct PrefixSnapshot {
    const PrefixIdentity identity;
    const std::vector<int32_t> tokens;
    const std::vector<uint8_t> bytes;
    PrefixSnapshot(PrefixIdentity key,std::vector<int32_t> prefix,std::vector<uint8_t> state)
        :identity(std::move(key)),tokens(std::move(prefix)),bytes(std::move(state)){}
};
class PrefixCache {
    const size_t limit_;
    std::unique_ptr<const PrefixSnapshot> entry_;
public:
    explicit PrefixCache(size_t limit):limit_(limit){}
    void clear(){entry_.reset();}
    size_t limit()const{return limit_;}
    size_t bytes()const{return entry_?entry_->bytes.size():0;}
    const PrefixSnapshot * find(const PrefixIdentity & key,const std::vector<int32_t> & prefix,
                                const std::vector<int32_t> & input) const {
        return entry_ && entry_->identity==key && entry_->tokens==prefix && prefix_matches(prefix,input)?entry_.get():nullptr;
    }
    bool install(PrefixIdentity key,std::vector<int32_t> prefix,std::vector<uint8_t> state) {
        clear();if(prefix.empty() || state.empty() || state.size()>limit_)return false;
        entry_=std::make_unique<const PrefixSnapshot>(std::move(key),std::move(prefix),std::move(state));return true;
    }
};
inline void prefix_cache_selftest(){
    auto prefix=static_prefix({1,2,3,10},{1,2,3,20});
    if(prefix!=std::vector<int32_t>({1,2}) || prefix_matches(prefix,{1,2}) || prefix_matches(prefix,{1,9,3}))throw std::runtime_error("static prefix boundary");
    PrefixIdentity key{"model","template","context","system"};PrefixCache cache(4);
    if(!cache.install(key,prefix,{7,8}) || !cache.find(key,prefix,{1,2,3,99}))throw std::runtime_error("prefix cache install");
    // Different user suffixes are okay; system/model/context/template are not.
    if(!cache.find(key,prefix,{1,2,42,98}))throw std::runtime_error("static-only reuse");
    for(int i=0;i<4;++i){auto changed=key;
        if(i==0)changed.model="other";if(i==1)changed.chat_template="other";if(i==2)changed.context="other";if(i==3)changed.system="other";
        if(cache.find(changed,prefix,{1,2,3}))throw std::runtime_error("cache identity mismatch");}
    if(cache.find(key,{1},{1,2,3}))throw std::runtime_error("prefix key mismatch");
    if(cache.install(key,prefix,{1,2,3,4,5}) || cache.bytes())throw std::runtime_error("snapshot byte bound");
}
