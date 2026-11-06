#pragma once
#include "llama.h"
#include <memory>
#include <stdexcept>
#include <string>

// Independently authored metadata-only tail of a backend sampler chain.
// The preceding upstream greedy sampler owns argmax and its tensor graph.
inline void filter_backend_outputs(llama_sampler_data * data) {
    // Retain diagnostics when an earlier backend sampler did not produce a
    // token. The worker will reject LLAMA_TOKEN_NULL, never sample stale logits.
    if (!data->sampled) return;
    data->logits = nullptr;
    data->probs = nullptr;
    data->candidates = nullptr;
}

inline llama_sampler * make_backend_output_filter() {
    // Process-lifetime vtable, null context, no borrowed memory or tensor refs.
    // llama_sampler_clone supports null-context samplers without a clone hook;
    // llama_sampler_free deletes the small wrapper with no custom free hook.
    static llama_sampler_i iface = [] {
        llama_sampler_i value{};
        value.name = [](const llama_sampler *) { return "velora-token-only"; };
        value.apply = [](llama_sampler *, llama_token_data_array *) {};
        value.backend_init = [](llama_sampler *, ggml_backend_buffer_type_t, uint32_t) { return true; };
        value.backend_apply = [](llama_sampler *, ggml_context *, ggml_cgraph *, llama_sampler_data * data) {
            filter_backend_outputs(data);
        };
        return value;
    }();
    return llama_sampler_init(&iface, nullptr);
}

inline void backend_output_filter_selftest() {
    std::unique_ptr<llama_sampler, decltype(&llama_sampler_free)> filter(make_backend_output_filter(), llama_sampler_free);
    std::unique_ptr<llama_sampler, decltype(&llama_sampler_free)> clone(llama_sampler_clone(filter.get()), llama_sampler_free);
    if (clone->ctx || filter->ctx || std::string(llama_sampler_name(clone.get())) != "velora-token-only")
        throw std::runtime_error("stateless backend filter clone");
    // Opaque non-null sentinels are compared/assigned only, never dereferenced.
    int marker = 0;
    auto * tensor = reinterpret_cast<ggml_tensor *>(&marker);
    llama_sampler_data data{tensor, tensor, nullptr, tensor};
    filter->iface->backend_apply(filter.get(), nullptr, nullptr, &data);
    if (data.logits != tensor || data.probs != tensor || data.candidates != tensor)
        throw std::runtime_error("filter discarded unavailable-sample diagnostics");
    data.sampled = tensor;
    clone->iface->backend_apply(clone.get(), nullptr, nullptr, &data);
    if (data.sampled != tensor || data.logits || data.probs || data.candidates)
        throw std::runtime_error("filter did not retain token-only output");
    llama_token_data token{7, 1.0f, 0.0f};
    llama_token_data_array candidates{&token, 1, 0, false};
    llama_sampler_apply(filter.get(), &candidates);
    if (candidates.selected != 0 || candidates.data[0].id != 7)
        throw std::runtime_error("CPU filter must not select tokens");
    llama_sampler_accept(filter.get(), 7);
    llama_sampler_reset(filter.get());
}
