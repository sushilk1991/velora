#pragma once
#include <algorithm>
#include <cstdint>
#include <stdexcept>
#include <vector>

struct CopyProposal { std::vector<int32_t> tokens; size_t start; };
// Independently authored alignment policy: prefer the next 3/2-token suffix
// occurrence at/after the cursor, otherwise the last earlier occurrence.
inline CopyProposal copy_proposal(const std::vector<int32_t> & source,
                                  const std::vector<int32_t> & output,size_t cursor,size_t limit) {
    limit=std::min<size_t>(limit,8);
    for(size_t n=std::min<size_t>(3,output.size());n>=2;--n){
        size_t found=source.size();
        for(size_t i=0;i+n<source.size();++i){
            if(!std::equal(output.end()-n,output.end(),source.begin()+i))continue;
            found=i+n;if(found>=cursor)break;
        }
        if(found<source.size())return {{source.begin()+found,source.begin()+std::min(source.size(),found+limit)},found};
    }
    return {{},cursor};
}
inline size_t verified_copy_prefix(const std::vector<int32_t> & proposed,const std::vector<int32_t> & choices) {
    if(proposed.size()!=choices.size())throw std::runtime_error("draft verification shape");
    size_t n=0;while(n<proposed.size() && proposed[n]==choices[n])++n;return n;
}
inline void copy_draft_selftest(){
    auto p=copy_proposal({1,2,3,4,1,2,5,6},{1,2},4,3);
    if(p.start!=6 || p.tokens!=std::vector<int32_t>({5,6}))throw std::runtime_error("draft cursor");
    p=copy_proposal({1,2,3,4,5,6},{1,2},99,3);
    if(p.tokens!=std::vector<int32_t>({3,4,5}))throw std::runtime_error("draft bound/fallback");
    p=copy_proposal({1,2,3,4,5,6,7,8,9,10,11},{1,2},0,99);
    if(p.tokens.size()!=8 || p.tokens.back()!=10)throw std::runtime_error("experimental draft cap");
    if(!copy_proposal({1,2,3},{1},0,3).tokens.empty() || !copy_proposal({1,2,3},{8,9},0,3).tokens.empty())throw std::runtime_error("draft no alignment");
    if(verified_copy_prefix({1,2,3},{1,2,3})!=3 || verified_copy_prefix({1,2,3},{1,8,3})!=1 || verified_copy_prefix({1,2},{9,2})!=0)throw std::runtime_error("target verification");
}
