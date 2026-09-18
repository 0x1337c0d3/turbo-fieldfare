# 8-bit shared-expert experiment

TurboFieldfare's default Gemma 4 install uses 4-bit affine weights for both the
dense shared experts and the 128 routed experts in each layer. This experiment
changes only the three shared-expert projections in each of the 30 layers to
8-bit. It is intended to test whether shared-expert precision materially
improves model quality before changing the routed-expert streaming format.

## Install

Use a separate output directory so the baseline and experiment remain easy to
identify. The installer streams only the required tensors and does not stage a
full source checkpoint.

```bash
swift run -c release TurboFieldfareRepack \
  --output scratch/gemma4-shared8.gturbo \
  --shared-expert-8bit
```

Resume an interrupted install by repeating the command with `--resume`. The
checkpoint fingerprint includes both source snapshots and the hybrid copy plan,
so it cannot be resumed with a different precision mode.

The primary snapshot remains
`mlx-community/gemma-4-26b-a4b-it-4bit` at commit
`0d77464eeb233a2da68ebf9d7dc4edaac7db956d`. The shared tensors come from
`mlx-community/gemma-4-26b-a4b-it-8bit` at commit
`33c6d23798a0af159529890f79329206dbfbd73c`. Both MLX snapshots identify the
same upstream Gemma base revision. The installer also pins and verifies each
snapshot's model index SHA-256.

The resulting manifest has this precision split:

| Weight class | Baseline | Experiment |
| --- | ---: | ---: |
| Embedding and attention | 4-bit | 4-bit |
| Router | 8-bit | 8-bit |
| Shared experts | 4-bit | 8-bit |
| Routed experts | 4-bit | 4-bit |

The hybrid adds about 268 MB to installed weight storage and the streamed
download. It does not alter expert-cache slots or routed-expert I/O.

## Compare quality

Treat sampled conversations as smoke tests, not quality evidence. Compare the
baseline and hybrid with identical prompt rendering, tokenizer, context limit,
and evaluation inputs:

1. Measure token-level negative log likelihood or perplexity on a fixed,
   versioned corpus. Use the same truncation and masking rules for both models.
2. Run deterministic task benchmarks with greedy decoding, or fix the random
   seed and sampling controls where greedy decoding is unsuitable.
3. Record exact-match or task-specific scores, paired per-example differences,
   and confidence intervals. Report regressions as well as aggregate gains.
4. Run the standard community performance benchmark separately. Report any
   change in time to first token, decode rate, resident memory, and I/O.

Do not attribute a difference to precision unless the evaluation harness feeds
the same tokens into both installations. If the hybrid does not show a stable
quality improvement, upgrading all routed experts is unlikely to be justified
by this experiment alone; it remains a separate hypothesis with a much larger
storage and streaming cost.
