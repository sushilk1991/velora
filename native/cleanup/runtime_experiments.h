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
    void validate(bool copy) const {
        if (draft_max < 1 || draft_max > 8) throw std::runtime_error("draft-max must be 1..8");
        if (recurrent_rollback && (!copy || draft_max < 2))
            throw std::runtime_error("recurrent rollback requires copy-draft and draft-max >=2");
        if (backend_sampling && direct_argmax) throw std::runtime_error("sampling experiments are mutually exclusive");
        if (backend_token_only && !backend_sampling) throw std::runtime_error("backend-token-only requires backend-sampling");
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
    RuntimeTrace trace;
    { RuntimeTrace::Timer timer(trace, "off"); }
    if (!trace.spans.empty()) throw std::runtime_error("disabled trace");
    trace.enabled = true;
    { RuntimeTrace::Timer timer(trace, "on"); }
    if (trace.spans.at("on").count != 1) throw std::runtime_error("trace counting");
}
