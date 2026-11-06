#pragma once
#include <chrono>
#include <cstdint>
#include <map>
#include <stdexcept>
#include <string>

// These switches change only the isolated research worker, never app defaults.
struct RuntimeExperiments {
    size_t draft_max = 3;
    bool recurrent_rollback = false;
    bool backend_sampling = false;
    bool direct_argmax = false;
    bool trace = false;
    bool backend_token_only = false;
    size_t prefill_batch = 128;
    bool research_long_context = false;
    int max_output_tokens = 512;
    bool bounded_swa = false;
    bool student_prefix_cache = false;
    void validate(bool copy) const {
        if (draft_max < 1 || draft_max > 8) throw std::runtime_error("draft-max must be 1..8");
        if (recurrent_rollback && (!copy || draft_max < 2))
            throw std::runtime_error("recurrent rollback requires copy-draft and draft-max >=2");
        if (backend_sampling && direct_argmax) throw std::runtime_error("sampling experiments are mutually exclusive");
        if (backend_token_only && !backend_sampling) throw std::runtime_error("backend-token-only requires backend-sampling");
        if (prefill_batch!=16 && prefill_batch!=32 && prefill_batch!=64 && prefill_batch!=128 && prefill_batch!=256 && prefill_batch!=512)
            throw std::runtime_error("prefill-batch must be 16,32,64,128,256,512");
        if (max_output_tokens<1 || max_output_tokens>2048 || (max_output_tokens>512 && !research_long_context))
            throw std::runtime_error("max-output-tokens above 512 requires research-long-context; maximum 2048");
    }
    void validate_context(int ctx) const {
        if(ctx<128 || (ctx>4096 && (!research_long_context || (ctx!=8192 && ctx!=16384))))
            throw std::runtime_error("context above 4096 requires research-long-context and 8192 or 16384");
    }
};

inline int32_t exact_greedy_argmax(const float * logits, size_t count) {
    if (!logits || !count) throw std::runtime_error("missing logits");
    size_t best = 0;
    // Same strict comparison and first-index tie behavior as upstream CPU greedy.
    for (size_t i = 1; i < count; ++i) if (logits[i] > logits[best]) best = i;
    return static_cast<int32_t>(best);
}

struct RuntimeTrace {
    struct Span { double ms = 0; uint64_t count = 0; };
    bool enabled = false;
    std::map<std::string, Span> spans;
    std::map<size_t, uint64_t> decode_sizes;
    struct Timer {
        RuntimeTrace & trace;
        const char * key;
        std::chrono::steady_clock::time_point start;
        Timer(RuntimeTrace & t, const char * k) : trace(t), key(k) {
            if (trace.enabled) start = std::chrono::steady_clock::now();
        }
        ~Timer() {
            if (!trace.enabled) return;
            const auto elapsed = std::chrono::steady_clock::now() - start;
            auto & span = trace.spans[key];
            span.ms += std::chrono::duration<double, std::milli>(elapsed).count();
            ++span.count;
        }
    };
    void reset() { spans.clear(); decode_sizes.clear(); }
};

inline void runtime_experiments_selftest() {
    const float ties[] = {-2, 4, 4, 0};
    if (exact_greedy_argmax(ties, 4) != 1) throw std::runtime_error("argmax tie behavior");
    const float negative[] = {-3, -1, -2};
    if (exact_greedy_argmax(negative, 3) != 1) throw std::runtime_error("argmax negatives");
    RuntimeExperiments defaults; defaults.validate(false);
    int rejected = 0;
    for (auto bad : {RuntimeExperiments{0}, RuntimeExperiments{9},
                     RuntimeExperiments{3,true}, RuntimeExperiments{3,false,true,true},
                     RuntimeExperiments{3,false,false,false,false,true}}) {
        try { bad.validate(false); } catch (const std::runtime_error &) { ++rejected; }
    }
    if (rejected != 5) throw std::runtime_error("experiment bounds");
    RuntimeExperiments{8,true}.validate(true);
    for (size_t size : {16,32,64,128,256,512}) {auto options=defaults;options.prefill_batch=size;options.validate(false);}
    auto research=defaults;research.research_long_context=true;research.max_output_tokens=2048;research.validate(false);research.validate_context(16384);
    int long_rejected=0;
    try {defaults.validate_context(8192);} catch(const std::runtime_error &) {++long_rejected;}
    try {research.validate_context(32768);} catch(const std::runtime_error &) {++long_rejected;}
    try {auto bad=defaults;bad.prefill_batch=17;bad.validate(false);} catch(const std::runtime_error &) {++long_rejected;}
    try {auto bad=defaults;bad.max_output_tokens=513;bad.validate(false);} catch(const std::runtime_error &) {++long_rejected;}
    if(long_rejected!=4)throw std::runtime_error("research bounds");
    RuntimeTrace trace;
    { RuntimeTrace::Timer timer(trace, "off"); }
    if (!trace.spans.empty()) throw std::runtime_error("disabled trace");
    trace.enabled = true;
    { RuntimeTrace::Timer timer(trace, "on"); }
    if (trace.spans.at("on").count != 1) throw std::runtime_error("trace counting");
}
