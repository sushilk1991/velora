"""Unmodified reference code from Underdog Bark 3.0 (CC BY 4.0).

Source: https://huggingface.co/ConwayResearch/Underdog-Bark-3.0 at revision
85db2ad18ab41e534a222ee253c29191d77ed919. UPSTREAM.json records each file's
upstream path, size, SHA-256, and git blob id. ``tests/test_bark.py`` fails
if any byte changes. NOTICE is the upstream attribution. LICENSE is the
upstream CC BY 4.0 legal code (``coreml/LICENSE`` in that repository).

    bark_loader.py  .bark container decoder (``load_state_dict``)
    bark_mlx.py     torch → MLX parameter renames (``to_mlx_names``)
    bark_coreml.py  ANE reference pipeline: numpy frontend, TDT decoder,
                    pause-aware ``segments``

Velora's adapters (``velora_engine.bark``) import these as modules and never
patch them. Change them only by re-vendoring a new pinned revision.
"""
