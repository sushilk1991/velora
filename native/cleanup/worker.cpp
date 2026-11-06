// Independently authored Velora experimental token loop (project license).
#include "llama.h"
#include "build_pin.h"
#include "chat.h"
#include "log.h"
#include "prefix_cache.h"
#include "copy_draft.h"
#include "runtime_experiments.h"
#include "backend_output_filter.h"
#include "nlohmann/json.hpp"
extern "C" {
#include "sha256.h"
}
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <memory>
#include <mutex>
#include <sstream>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>
#include <sys/stat.h>
#include <unistd.h>
#include <mach/mach.h>
using json = nlohmann::json;
using Clock = std::chrono::steady_clock;
static constexpr const char * PIN = VELORA_LLAMA_COMMIT;
static std::mutex output_mutex;
static void emit(const json & value) {
    std::lock_guard<std::mutex> lock(output_mutex);
    std::cout << value.dump(-1, ' ', false, json::error_handler_t::replace) << '\n' << std::flush;
}
static uint64_t rss() {
    mach_task_basic_info info{}; mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
    if (task_info(mach_task_self(), MACH_TASK_BASIC_INFO, (task_info_t)&info, &count) != KERN_SUCCESS) return 0;
    return info.resident_size;
}
static std::string sha(FILE * file) {
    sha256_t state; sha256_init(&state); unsigned char buffer[65536];
    while (size_t n = fread(buffer, 1, sizeof(buffer), file)) sha256_update(&state, buffer, n);
    if (ferror(file)) throw std::runtime_error("model read failed");
    unsigned char digest[32]; sha256_final(&state, digest); rewind(file);
    std::ostringstream out; for (auto c : digest) out << std::hex << std::setw(2) << std::setfill('0') << int(c);
    return out.str();
}
static std::string hash_text(const std::string & text) {
    unsigned char digest[32]; sha256_hash(digest, (const unsigned char*)text.data(), text.size());
    std::ostringstream out; for (auto c : digest) out << std::hex << std::setw(2) << std::setfill('0') << int(c);
    return out.str();
}
static bool bounded_line(std::string & line) {
    line.clear(); bool large = false; char c;
    while (std::cin.get(c)) {
        if (c == '\n') { if (large) throw std::runtime_error("request exceeds 1 MiB"); return true; }
        if (line.size() < 1024 * 1024) line.push_back(c); else large = true;
    }
    if (large) throw std::runtime_error("request exceeds 1 MiB");
    return !line.empty();
}
static std::string field(const json & request, const char * key, size_t limit) {
    auto text = request.at(key).get<std::string>();
    if (text.empty() || text.size() > limit) throw std::runtime_error(std::string("invalid ") + key);
    return text;
}
static int integer(const json & r, const char * key, int fallback, int low, int high) {
    if (r.contains(key) && !r.at(key).is_number_integer()) throw std::runtime_error(std::string("integer required: ") + key);
    int value = r.value(key, fallback);
    if (value < low || value > high) throw std::runtime_error(std::string("out of range: ") + key);
    return value;
}
static json request_error(const json & request, const std::string & message) {
    json result={{"event","error"},{"error",message}};
    if(request.is_object() && request.contains("id") && request["id"].is_string()) {
        auto id=request["id"].get<std::string>();
        if(!id.empty() && id.size()<=128)result["id"]=id;
    }
    return result;
}
struct Request {
    std::string id, system, user;
    int max_tokens, deadline_ms;
    std::string draft_text;
    static Request parse(const json & r) {
        Request q{field(r,"id",128),field(r,"system",16384),field(r,"user",65536),
                  integer(r,"max_tokens",256,1,512),integer(r,"deadline_ms",10000,1,120000)};
        if(r.contains("draft_text")){
            if(!r.at("draft_text").is_string())throw std::runtime_error("invalid draft_text");
            q.draft_text=r.at("draft_text").get<std::string>();
            if(q.draft_text.size()>65536)throw std::runtime_error("invalid draft_text");
        }
        // Fail closed until the production neutralize/restore contract is ported.
        // Never return serialized model input as fallback text.
        for (const auto & s : {q.system, q.user})
            if (s.find("<|") != std::string::npos || s.find("<think>") != std::string::npos || s.find("</think>") != std::string::npos)
                throw std::runtime_error("control-token-like input requires parent neutralization");
        return q;
    }
};
struct Cancellation {
    std::atomic<bool> cancelled{false};
    Clock::time_point deadline;
    uint64_t max_rss;
    std::string reason() const {
        if (cancelled.load()) return "cancelled";
        if (Clock::now() >= deadline) return "deadline";
        if (rss() > max_rss) return "memory_limit";
        return "";
    }
    static bool abort(void * p) { return !static_cast<Cancellation*>(p)->reason().empty(); }
};
struct Runtime {
    std::unique_ptr<llama_model, decltype(&llama_model_free)> model{nullptr,llama_model_free};
    // Declared before context so the context is freed before its borrowed chain.
    std::unique_ptr<llama_sampler, decltype(&llama_sampler_free)> backend_greedy{nullptr,llama_sampler_free};
    std::unique_ptr<llama_context, decltype(&llama_free)> context{nullptr,llama_free};
    common_chat_templates_ptr templates;
    const llama_vocab * vocab = nullptr;
    uint32_t context_size;
    bool cache_enabled, copy_enabled;
    RuntimeExperiments experiments;
    RuntimeTrace trace;
    uint64_t forward_calls=0,forward_tokens=0;
    uint64_t backend_sampled_tokens=0,filtered_rows_checked=0;
    PrefixCache prefix_cache{32*1024*1024};
    PrefixIdentity cache_identity;
    Cancellation control;
    std::mutex state_mutex;
    std::string active_id;
    bool active = false;
    std::thread worker;
    Runtime(const std::string & path, const std::string & expected, int layers, int ctx, int max_mb, bool cache,bool copy,RuntimeExperiments options) : context_size(ctx), cache_enabled(cache),copy_enabled(copy),experiments(options) {
        experiments.validate(copy);trace.enabled=experiments.trace;
        if (expected.size()!=64 || expected.find_first_not_of("0123456789abcdef")!=std::string::npos) throw std::runtime_error("expected lowercase SHA256 required");
        std::unique_ptr<FILE, decltype(&fclose)> f(fopen(path.c_str(),"rb"),fclose);
        if (!f) throw std::runtime_error("local model file missing");
        struct stat before{}, after{}; fstat(fileno(f.get()),&before);
        if (!S_ISREG(before.st_mode) || before.st_size<=0 || before.st_size>4LL*1024*1024*1024) throw std::runtime_error("model must be a regular file <=4 GiB");
        if (sha(f.get())!=expected) throw std::runtime_error("model SHA256 mismatch");
        fstat(fileno(f.get()),&after);
        if (before.st_size!=after.st_size || before.st_mtimespec.tv_sec!=after.st_mtimespec.tv_sec || before.st_mtimespec.tv_nsec!=after.st_mtimespec.tv_nsec) throw std::runtime_error("model changed during verification");
        // Same verified descriptor, mmap off: never resolve a repo or download.
        llama_backend_init();
        auto mp=llama_model_default_params();mp.n_gpu_layers=layers;mp.load_mode=LLAMA_LOAD_MODE_NONE;
        model.reset(llama_model_load_from_file_ptr(f.get(),mp));
        if (!model) throw std::runtime_error("local GGUF load failed");
        vocab=llama_model_get_vocab(model.get());
        char architecture[128]{};llama_model_meta_val_str(model.get(),"general.architecture",architecture,sizeof(architecture));
        std::string arch=architecture;
        if (arch!="lfm3" && arch!="qwen35" && arch!="qwen3") throw std::runtime_error("unqualified model architecture: "+arch);
        control.max_rss=uint64_t(max_mb)*1024*1024;
        control.deadline=Clock::time_point::max();
        auto cp=llama_context_default_params();cp.n_ctx=ctx;cp.n_batch=128;cp.n_ubatch=128;cp.n_seq_max=1;
        cp.n_threads=4;cp.n_threads_batch=4;cp.abort_callback=Cancellation::abort;cp.abort_callback_data=&control;
        if(experiments.recurrent_rollback)cp.n_rs_seq=experiments.draft_max-1;
        llama_sampler_seq_config sampler_config{};
        if(experiments.backend_sampling){
            // Prefill requests its final row only; verification requests at
            // most draft_max rows. The default per-sequence cap is only one.
            cp.n_outputs_max=copy_enabled?experiments.draft_max:1;
            cp.n_outputs_max_per_seq=cp.n_outputs_max;
            backend_greedy.reset(llama_sampler_chain_init(llama_sampler_chain_default_params()));
            llama_sampler_chain_add(backend_greedy.get(),llama_sampler_init_greedy());
            if(experiments.backend_token_only)
                llama_sampler_chain_add(backend_greedy.get(),make_backend_output_filter());
            sampler_config={0,backend_greedy.get()};cp.samplers=&sampler_config;cp.n_samplers=1;
        }
        context.reset(llama_init_from_model(model.get(),cp));
        if (!context) throw std::runtime_error("context allocation failed");
        if(experiments.recurrent_rollback && llama_n_rs_seq(context.get())!=experiments.draft_max-1)
            throw std::runtime_error("requested recurrent rollback unsupported");
        templates=common_chat_templates_init(model.get(),"");
        if (!common_chat_templates_support_enable_thinking(templates.get())) throw std::runtime_error("model template lacks verified thinking toggle");
        cache_identity={expected,hash_text(common_chat_templates_source(templates.get())),
            std::string(PIN)+":"+std::to_string(reinterpret_cast<uintptr_t>(context.get()))+":"+std::to_string(llama_n_ctx(context.get()))+":batch128:ubatch128:seq1:"+std::to_string(layers)+":"+std::to_string(cp.type_k)+":"+std::to_string(cp.type_v)+":rs"+std::to_string(cp.n_rs_seq)+":backend"+std::to_string(experiments.backend_sampling)+":tokenonly"+std::to_string(experiments.backend_token_only),""};
        if (rss()>control.max_rss) throw std::runtime_error("resident memory limit exceeded during load");
        emit({{"event","ready"},{"pid",getpid()},{"protocol",1},{"llama_commit",PIN},{"architecture",arch},{"model_sha256",expected},
              {"template_sha256",hash_text(common_chat_templates_source(templates.get()))},{"vocab_size",llama_vocab_n_tokens(vocab)},
              {"context_tokens",ctx},{"batch_tokens",128},{"max_rss_mb",max_mb},{"rss_bytes",rss()},{"copy_draft",copy_enabled},{"copy_draft_max",experiments.draft_max},{"prefix_reuse",cache_enabled},{"prefix_cache_limit_bytes",prefix_cache.limit()},
              {"recurrent_rollback",experiments.recurrent_rollback},{"recurrent_snapshots",llama_n_rs_seq(context.get())},{"sampling",experiments.backend_sampling?"backend_greedy":experiments.direct_argmax?"direct_cpu_argmax":"upstream_cpu_greedy"},{"sampling_output_reserve",cp.n_outputs_max_per_seq},{"backend_token_only",experiments.backend_token_only},{"trace_runtime",experiments.trace}});
    }
    ~Runtime() {control.cancelled=true;if(worker.joinable())worker.join();}
    void decode(const std::vector<llama_token> & tokens, int position,bool all_logits=false) {
        RuntimeTrace::Timer timer(trace,"decode_submit");
        if(trace.enabled)++trace.decode_sizes[tokens.size()];
        ++forward_calls;forward_tokens+=tokens.size();
        std::unique_ptr<llama_batch_ext,decltype(&llama_batch_ext_free)> batch(llama_batch_ext_init(context.get()),llama_batch_ext_free);
        for(size_t i=0;i<tokens.size();++i){auto index=llama_batch_ext_add_token(batch.get(),0,tokens[i]);llama_pos pos=position+i;llama_batch_ext_set_pos(batch.get(),index,&pos);}
        for(size_t i=0;i<tokens.size();++i)if(all_logits || i+1==tokens.size())
            if(!llama_batch_ext_set_output_logits(batch.get(),i,true))throw std::runtime_error("batch logits unavailable");
        int result=llama_process(context.get(),LLAMA_PROCESS_TYPE_DECODE,batch.get());
        if(result){auto reason=control.reason();throw std::runtime_error(reason.empty()?"decode_error":reason);}
    }
    std::vector<llama_token> prompt_tokens(const std::string & system_text,const std::string & user_text) {
        RuntimeTrace::Timer timer(trace,"prompt_render_tokenize");
        common_chat_templates_inputs ci;ci.enable_thinking=false;ci.add_generation_prompt=true;
        common_chat_msg system,user;system.role="system";system.content=system_text;user.role="user";user.content=user_text;ci.messages={system,user};
        auto rendered=common_chat_templates_apply(templates.get(),ci).prompt.str();
        int n=-llama_tokenize(vocab,rendered.data(),rendered.size(),nullptr,0,true,true);
        if(n<=0 || uint64_t(n)>context_size)throw std::runtime_error("context_limit");
        std::vector<llama_token> tokens(n);
        if(llama_tokenize(vocab,rendered.data(),rendered.size(),tokens.data(),n,true,true)!=n)throw std::runtime_error("tokenization_error");
        return tokens;
    }
    void prefill(const std::vector<llama_token> & tokens,int start,int end) {
        RuntimeTrace::Timer timer(trace,"prefill_submit_inclusive");
        for(int offset=start;offset<end;offset+=128){if(auto reason=control.reason();!reason.empty())throw std::runtime_error(reason);
            decode(std::vector<llama_token>(tokens.begin()+offset,tokens.begin()+std::min(end,offset+128)),offset);}
    }
    int prepare_prefix(const Request & q,const std::vector<llama_token> & input,json & metrics) {
        if(!cache_enabled)return 0;
        // Independent sentinel first tokens: cache construction never sees q.user.
        auto prefix=static_prefix(prompt_tokens(q.system,"A"),prompt_tokens(q.system,"中"));
        auto key=cache_identity;key.system=hash_text(q.system);
        if(!prefix_matches(prefix,input)){prefix_cache.clear();metrics["reason"]="prefix_mismatch";return 0;}
        metrics["prefix_tokens"]=prefix.size();
        if(const auto * saved=prefix_cache.find(key,prefix,input)){
            RuntimeTrace::Timer timer(trace,"prefix_restore");
            size_t restored=llama_state_seq_set_data(context.get(),saved->bytes.data(),saved->bytes.size(),0);
            if(restored==saved->bytes.size() && llama_memory_seq_pos_max(llama_get_memory(context.get()),0)==int(prefix.size())-1){
                metrics["hit"]=true;metrics["reason"]="restored";return prefix.size();
            }
            // Any partial restore is discarded; never keep mixed recurrent/KV state.
            prefix_cache.clear();llama_memory_clear(llama_get_memory(context.get()),true);
            metrics["reason"]="restore_failed_full_reset";return 0;
        }
        prefix_cache.clear();prefill(prefix,0,prefix.size());
        if(auto reason=control.reason();!reason.empty())throw std::runtime_error(reason);
        size_t size=llama_state_seq_get_size(context.get(),0);
        if(size>0 && size<=prefix_cache.limit()){
            std::vector<uint8_t> bytes(size);
            size_t written=llama_state_seq_get_data(context.get(),bytes.data(),bytes.size(),0);
            if(written==size && llama_memory_seq_pos_max(llama_get_memory(context.get()),0)==int(prefix.size())-1 && prefix_cache.install(key,prefix,std::move(bytes))){
                metrics["reason"]="captured_static_prefix";return prefix.size();
            }
        }
        prefix_cache.clear();llama_memory_clear(llama_get_memory(context.get()),true);
        metrics["reason"]="save_failed_or_oversized_full_reset";return 0;
    }
    std::vector<llama_token> draft_tokens(const std::string & text) {
        if(text.empty())return {};
        int n=-llama_tokenize(vocab,text.data(),text.size(),nullptr,0,false,false);
        if(n<=0 || n>65536)return {};
        std::vector<llama_token> tokens(n);
        if(llama_tokenize(vocab,text.data(),text.size(),tokens.data(),n,false,false)!=n)throw std::runtime_error("draft tokenization failed");
        return tokens;
    }
    void append_token(llama_token token,std::string & answer,std::vector<llama_token> & output){
        if(experiments.backend_sampling)llama_sampler_accept(backend_greedy.get(),token);
        output.push_back(token);char piece[512];int length=llama_token_to_piece(vocab,token,piece,sizeof(piece),0,true);
        if(length>=0)answer.append(piece,length);else{std::vector<char> large(-length);int written=llama_token_to_piece(vocab,token,large.data(),large.size(),0,true);if(written<0)throw std::runtime_error("detokenization_error");answer.append(large.data(),written);}
    }
    llama_token sample(llama_sampler * greedy,int index){
        RuntimeTrace::Timer timer(trace,"sample_wait_inclusive");
        if(experiments.backend_sampling){
            auto token=llama_get_sampled_token_ith(context.get(),index);
            if(token==LLAMA_TOKEN_NULL)throw std::runtime_error("backend_sampling_unavailable");
            ++backend_sampled_tokens;
            if(experiments.backend_token_only){
                // Read copy bookkeeping only, after the sampled-token getter's
                // existing completion wait. Never fetch/fall back to logits.
                if(llama_get_sampled_logits_count_ith(context.get(),index)!=0 ||
                   llama_get_sampled_probs_count_ith(context.get(),index)!=0 ||
                   llama_get_sampled_candidates_count_ith(context.get(),index)!=0)
                    throw std::runtime_error("backend_token_only_output_leak");
                ++filtered_rows_checked;
            }
            return token;
        }
        if(experiments.direct_argmax){
            const float * logits=llama_get_logits_ith(context.get(),index);
            RuntimeTrace::Timer cpu_timer(trace,"cpu_argmax_only");
            return exact_greedy_argmax(logits,llama_vocab_n_tokens(vocab));
        }
        return llama_sampler_sample(greedy,context.get(),index);
    }
    std::string generate(const Request & q,int n,std::string & answer,std::vector<llama_token> & output,json & stats){
        std::unique_ptr<llama_sampler,decltype(&llama_sampler_free)> greedy(llama_sampler_init_greedy(),llama_sampler_free);
        auto source=copy_enabled?draft_tokens(q.draft_text):std::vector<llama_token>{};
        bool enabled=copy_enabled && !source.empty();size_t cursor=0;
        // Request-owned user-conditioned scratch; never inserted in static cache.
        std::vector<uint8_t> scratch;constexpr size_t cap=32*1024*1024;
        stats["source_tokens"]=source.size();
        while(output.size()<size_t(q.max_tokens)){
            if(auto reason=control.reason();!reason.empty())throw std::runtime_error(reason);
            auto expected=sample(greedy.get(),-1);
            if(llama_vocab_is_eog(vocab,expected))return "eos";
            auto proposal=enabled?copy_proposal(source,output,cursor,std::min(experiments.draft_max,q.max_tokens-output.size())):CopyProposal{{},cursor};
            // No draft EOG is eligible for acceptance. The target owns stopping.
            auto eog=std::find_if(proposal.tokens.begin(),proposal.tokens.end(),[&](auto t){return llama_vocab_is_eog(vocab,t);});proposal.tokens.erase(eog,proposal.tokens.end());
            if(proposal.tokens.size()<2 || proposal.tokens[0]!=expected){
                append_token(expected,answer,output);
                if(output.size()<size_t(q.max_tokens))decode({expected},n+output.size()-1);
                continue;
            }
            size_t bytes=0;
            if(!experiments.recurrent_rollback){
                RuntimeTrace::Timer timer(trace,"draft_snapshot_save");
                bytes=llama_state_seq_get_size(context.get(),0);
                bool saved=false;
                if(bytes && bytes<=cap){scratch.resize(bytes);saved=llama_state_seq_get_data(context.get(),scratch.data(),bytes,0)==bytes;}
                if(!saved){enabled=false;stats["fallback"]="snapshot_unavailable_or_oversized";continue;}
                stats["snapshot_peak_bytes"]=std::max(stats["snapshot_peak_bytes"].get<size_t>(),bytes);
                stats["snapshot_saved_bytes"]=stats["snapshot_saved_bytes"].get<size_t>()+bytes;
            }
            int position=n+output.size();
            decode(proposal.tokens,position,true);
            if(auto reason=control.reason();!reason.empty())throw std::runtime_error(reason);
            std::vector<llama_token> choices{expected};
            for(size_t i=1;i<proposal.tokens.size();++i){
                choices.push_back(sample(greedy.get(),i-1));
            }
            size_t accepted=verified_copy_prefix(proposal.tokens,choices);
            if(accepted==0)throw std::runtime_error("draft lost preverified first token");
            stats["proposed"]=stats["proposed"].get<size_t>()+proposal.tokens.size();
            stats["accepted"]=stats["accepted"].get<size_t>()+accepted;
            std::vector<llama_token> verified(proposal.tokens.begin(),proposal.tokens.begin()+accepted);
            bool eos=false;
            if(accepted<proposal.tokens.size()){
                stats["rollbacks"]=stats["rollbacks"].get<size_t>()+1;
                if(experiments.recurrent_rollback){
                    RuntimeTrace::Timer timer(trace,"draft_device_rollback");
                    // The first draft token was verified before decoding, so a
                    // rollback never asks for the pre-batch recurrent state.
                    auto memory=llama_get_memory(context.get());
                    if(!llama_memory_seq_rm(memory,0,position+accepted,-1) ||
                       llama_memory_seq_pos_max(memory,0)!=position+int(accepted)-1)
                        throw std::runtime_error("draft_device_rollback_failed");
                }else{
                    RuntimeTrace::Timer timer(trace,"draft_snapshot_restore");
                    llama_memory_clear(llama_get_memory(context.get()),true);
                    if(llama_state_seq_set_data(context.get(),scratch.data(),bytes,0)!=bytes || llama_memory_seq_pos_max(llama_get_memory(context.get()),0)!=position-1)throw std::runtime_error("draft_restore_failed");
                }
                eos=llama_vocab_is_eog(vocab,choices[accepted]);
                if(!eos)verified.push_back(choices[accepted]);
                // No saved logits are sampled. Replay regenerates logits for the
                // next iteration; EOS/ceiling paths do not need another sample.
                if(!eos && output.size()+verified.size()<size_t(q.max_tokens)){
                    RuntimeTrace::Timer timer(trace,"rollback_replay_submit_inclusive");
                    if(experiments.recurrent_rollback)decode({choices[accepted]},position+accepted);
                    else decode(verified,position);
                }
            }
            if(auto reason=control.reason();!reason.empty())throw std::runtime_error(reason);
            cursor=proposal.start+accepted;
            for(auto token:verified)append_token(token,answer,output);
            if(eos)return "eos";
        }
        return "length";
    }
    void run(Request q) {
        trace.reset();
        if(backend_greedy)llama_sampler_reset(backend_greedy.get());
        forward_calls=0;forward_tokens=0;
        backend_sampled_tokens=0;filtered_rows_checked=0;
        json copy_stats={{"enabled",copy_enabled},{"proposed",0},{"accepted",0},{"rollbacks",0},{"snapshot_peak_bytes",0},{"snapshot_saved_bytes",0},{"fallback",nullptr}};
        auto start=Clock::now();std::string answer,status="length";std::vector<llama_token> output;std::vector<llama_token> input;
        json cache_metrics={{"enabled",cache_enabled},{"hit",false},{"prefix_tokens",0},{"reason",cache_enabled?"miss":"disabled"}};
        try {
            input=prompt_tokens(q.system,q.user);int n=input.size();
            if(uint64_t(n)+q.max_tokens>context_size)throw std::runtime_error("context_limit");
            llama_memory_clear(llama_get_memory(context.get()),true);
            int prefix=prepare_prefix(q,input,cache_metrics);
            // Always decode >=1 token after restore: serialized state has no logits.
            if(prefix>=n)throw std::runtime_error("unsafe_cached_logits");
            prefill(input,prefix,n);
            status=generate(q,n,answer,output,copy_stats);
        }catch(const std::exception & e){status=e.what();}
        // Only the immutable static prefix snapshot survives; live user state is cleared.
        llama_memory_clear(llama_get_memory(context.get()),true);
        cache_metrics["snapshot_bytes"]=prefix_cache.bytes();
        copy_stats["forward_calls"]=forward_calls;copy_stats["forward_tokens"]=forward_tokens;
        auto ms=std::chrono::duration<double,std::milli>(Clock::now()-start).count();
        {std::lock_guard<std::mutex> lock(state_mutex);active=false;}
        json result={{"event","result"},{"id",q.id},{"status",status},{"text",status=="eos"?answer:""},
              {"partial_text",status=="eos"?"":answer},{"prompt_tokens",input},{"output_tokens",output},{"elapsed_ms",ms},{"rss_bytes",rss()},{"prefix_cache",cache_metrics},{"copy_draft",copy_stats}};
        result["backend_sampling"]={{"enabled",experiments.backend_sampling},{"token_only",experiments.backend_token_only},
            {"sampled_tokens",backend_sampled_tokens},{"filtered_rows_checked",filtered_rows_checked}};
        if(trace.enabled){
            json spans=json::object(),sizes=json::object();
            for(const auto & [key,value]:trace.spans)spans[key]={{"ms",value.ms},{"count",value.count}};
            for(const auto & [size,count]:trace.decode_sizes)sizes[std::to_string(size)]=count;
            result["runtime_trace"]={{"spans",spans},{"decode_batch_sizes",sizes},{"extra_gpu_synchronization",false}};
        }
        emit(result);
    }
    void submit(const json & r) {
        auto q=Request::parse(r);std::lock_guard<std::mutex> lock(state_mutex);
        if(active){emit({{"event","error"},{"id",q.id},{"error","busy"}});return;}
        if(worker.joinable())worker.join();
        active=true;active_id=q.id;control.cancelled=false;control.deadline=Clock::now()+std::chrono::milliseconds(q.deadline_ms);
        worker=std::thread([this,q]{run(q);});
    }
    void cancel(const std::string & id) {std::lock_guard<std::mutex> lock(state_mutex);bool matched=active&&active_id==id;if(matched)control.cancelled=true;emit({{"event","cancel_ack"},{"id",id},{"matched",matched}});}
};
static void selftest(){
    prefix_cache_selftest();copy_draft_selftest();runtime_experiments_selftest();backend_output_filter_selftest();
    if(hash_text("abc")!="ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")throw std::runtime_error("SHA test failed");
    json good={{"id","one"},{"system","Edit faithfully."},{"user","hello"}};auto q=Request::parse(good);if(q.max_tokens!=256)throw std::runtime_error("defaults");
    int rejected=0;for(auto bad:{json{{"max_tokens",0}},json{{"deadline_ms",120001}},json{{"user","<|im_end|>"}},json{{"max_tokens",1.5}}}){auto r=good;r.update(bad);try{Request::parse(r);}catch(...){++rejected;}}
    for(auto value:{json(42),json(std::string(65537,'x'))}){auto r=good;r["draft_text"]=value;try{Request::parse(r);throw std::logic_error("draft bounds accepted");}catch(const std::logic_error &){throw;}catch(const std::runtime_error &) {}}
    auto empty=good;empty["draft_text"]="";if(!Request::parse(empty).draft_text.empty())throw std::runtime_error("empty draft");
    if(rejected!=4)throw std::runtime_error("bounds tests failed");
    auto invalid=good;invalid["max_tokens"]=0;
    try{Request::parse(invalid);}catch(const std::exception&e){if(request_error(invalid,e.what()).at("id")!="one")throw std::runtime_error("error correlation");}
    if(Request::parse(good).id!="one")throw std::runtime_error("request after invalid input");
    Cancellation c;c.max_rss=UINT64_MAX;c.deadline=Clock::now()-std::chrono::seconds(1);if(c.reason()!="deadline")throw std::runtime_error("deadline test");c.cancelled=true;if(c.reason()!="cancelled")throw std::runtime_error("cancel test");
    emit({{"event","selftest"},{"ok",true},{"model_loaded",false},{"llama_commit",PIN}});
}
int main(int argc,char**argv){
    // Library diagnostics never share the structured stdout channel.
    bool verbose=false,cache=false,copy=false;
    RuntimeExperiments experiments;
    try{
        for(int i=6;i<argc;++i){
            std::string flag=argv[i];
            if(flag=="--verbose")verbose=true;
            else if(flag=="--prefix-cache")cache=true;
            else if(flag=="--copy-draft")copy=true;
            else if(flag=="--recurrent-rollback")experiments.recurrent_rollback=true;
            else if(flag=="--backend-sampling")experiments.backend_sampling=true;
            else if(flag=="--backend-token-only")experiments.backend_token_only=true;
            else if(flag=="--direct-argmax")experiments.direct_argmax=true;
            else if(flag=="--trace-runtime")experiments.trace=true;
            else if(flag.rfind("--draft-max=",0)==0){
                const auto value=flag.substr(12);
                if(value.empty() || value.find_first_not_of("0123456789")!=std::string::npos)
                    throw std::runtime_error("draft-max must be an integer");
                experiments.draft_max=std::stoul(value);
            }else throw std::runtime_error("unknown startup flag");
        }
        experiments.validate(copy);
    }catch(const std::exception & e){emit({{"event","fatal"},{"error",e.what()}});return 1;}
    common_log_set_verbosity_thold(verbose?LOG_LEVEL_DEBUG:LOG_LEVEL_WARN);
    llama_log_set([](ggml_log_level level,const char*text,void*user){if(*static_cast<bool*>(user) || level==GGML_LOG_LEVEL_WARN || level==GGML_LOG_LEVEL_ERROR)fputs(text,stderr);},&verbose);
    try{
        if(argc==2&&std::string(argv[1])=="--selftest"){selftest();return 0;}
        if(argc<3)throw std::runtime_error("usage: worker LOCAL_GGUF SHA256 [gpu_layers=99] [context=4096] [max_rss_mb=8192]");
        int layers=argc>3?std::stoi(argv[3]):99,ctx=argc>4?std::stoi(argv[4]):4096,mb=argc>5?std::stoi(argv[5]):8192;
        if(layers<0||layers>999||ctx<128||ctx>4096||mb<512||mb>32768)throw std::runtime_error("invalid startup limits");
        Runtime runtime(argv[1],argv[2],layers,ctx,mb,cache,copy,experiments);std::string line;
        for(;;){json request;try{
            if(!bounded_line(line))break;
            request=json::parse(line);const auto & r=request;auto op=r.at("op").get<std::string>();
            if(op=="generate")runtime.submit(r);
            else if(op=="cancel")runtime.cancel(field(r,"id",128));
            else if(op=="ping")emit({{"event","pong"}});
            else if(op=="shutdown")break;
            else throw std::runtime_error("unknown operation");
        }catch(const std::exception&e){emit(request_error(request,e.what()));}}
        return 0;
    }catch(const std::exception&e){emit({{"event","fatal"},{"error",e.what()}});return 1;}
}
