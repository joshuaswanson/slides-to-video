# Presentation Script - Modal Aphasia (5 minutes)

---

## Slide 1 - Title Slide

We present modal aphasia ... a systematic dissociation in unified multimodal models where they can accurately generate visual content but fail to describe it in text.

---

## Slide 2 - Unified representation spaces enable cross-modal reasoning

Let's start with some context. Modern multimodal models like GPT-4o and Gemini use a unified architecture, where all modalities share the same representation space. In principle, this enables cross-modal reasoning. ...

For example, you can describe something, and the model generates an image of it. ...

Or input an image, and the model should be able to describe what's in it.

---

## Slide 3 - (Same slide, with paper snippets appearing)

And there's good reason to believe today's frontier models work this way. Technical reports and system cards describe these systems as "natively multimodal," or trained on "interleaved text and image data" within a single network. So according to the model providers themselves, these are genuinely unified architectures.

---

## Slide 4 - "But do those models really _understand_ what they can generate?"

But do those models really understand what they can draw? If the representation is really unified, knowledge should be accessible in every modality equally.

---

## Slide 5 - Harry Potter poster (image only)

As an example, we ask ChatGPT-4o to reproduce a well-known movie poster, purely from memory.

---

## Slide 6 - Harry Potter poster (with green checkmarks)

And the result is remarkably accurate. The model gets almost every detail right.

---

## Slide 7 - Harry Potter poster (with text description appearing)

We then independently ask the same model to describe that same poster in text, again purely from memory, and it produces this detailed description. Since the model can generate an image of this poster almost perfectly, it should, in theory, also be able to describe it verbally, because in a unified representation space, all modalities share the same underlying representation.

---

## Slide 8 - Harry Potter poster (description with red/green highlights)

But when we check the description against the real poster, we find many mistakes. The model fabricates characters and objects that aren't on the poster, and misidentifies key details.

---

## Slide 9 - Modal Aphasia definition overlay

We term this phenomenon Modal Aphasia: a systematic failure of models to express what they can perfectly draw. The name is inspired by aphasia in humans, where language production is impaired despite intact underlying cognition.

---

## Slide 10 - "Modal Aphasia exists in real-world frontier models" (blank)

First we demonstrate that modal aphasia exists in real-world frontier models. Specifically, we study this behavior systematically on ChatGPT-4o across nine movie posters.

---

## Slide 11 - Error rate bar chart (Image vs Text)

We found that verbal descriptions contain over 7 times more errors than generated images. And the majority of those errors are hallucinations, not just omissions.

---

## Slide 12 - Both charts (error rates + hallucination breakdown)

Looking at the hallucination breakdown more closely: verbal descriptions contain lots of fabricated details, like mentioning characters or objects that are simply not in the real poster. In contrast, generated images almost never contain such fabrications, only occasional minor inaccuracies.

---

## Slide 13 - Overlay: "We perform a systematic study on open-weight models"

Now, our control over proprietary frontier models is limited, so we also perform a systematic study on open-weight models using generated faces and abstract shapes. Specifically, we fine-tune two open-weight unified models, Janus-Pro and Harmon, on synthetic datasets with known ground truth. We find that modal aphasia emerges reliably across both architectures, confirming it's a fundamental property of these models, not just an artifact of any particular training setup. For details on those experiments, see our paper.

---

## Slide 14 - "Modal Aphasia may cause safety risks" - Safety training

Modal aphasia also has implications for AI safety. Safety filters are typically applied unevenly across modalities. As a simple example, consider a naive safety training setup where the model learns to reject requests for potentially harmful content. Here we use "feet" as a stand-in for sensitive content.

---

## Slide 15 - Safety training + Training data

Now, the model's training data contains a mix of benign images and sensitive content. The key observation is that some obscure internet forum might refer to feet using a rare niche term, say, "secondary balance units."

---

## Slide 16 - Safety training + Training data + Inference (safe concepts)

After safety training, the model works as intended for common terms. It generates benign images just fine, and it correctly refuses when you ask for feet using the common word. Now, if the model truly understood what images it generates, it would also refuse when prompted with a rare term like "secondary balance units."

---

## Slide 17 - Full safety slide with rare expression bypass

But due to modal aphasia, that's not what happens. The model doesn't connect the rare textual expression to the visual concept it has learned to refuse. The model generates the sensitive content anyway. The safety training only covered the text side, and the visual knowledge remains accessible through this alternative route.

---

## Slide 18 - "See our paper for the full case study"

We demonstrate this concretely with a controlled case study on Janus-Pro in the paper. See our paper for the full details.

---

## Slide 19 - Takeaways

To sum up: Modal Aphasia is a phenomenon in which models with unified representation spaces, systematically fail to access knowledge in some modalities but not others. We observe this consistently across architectures and datasets, in both frontier and open-weight models.

Second, modal aphasia can circumvent safe guards. Specifically, naive safety filters can be bypassed by exploiting cross-modal gaps in the model's knowledge.

Looking ahead, we think resolving modal aphasia will require models to visualize concepts in their thinking, not just as an output channel.

All of our code, data, and full results are publicly available by scanning the QR code here.

Thank you.