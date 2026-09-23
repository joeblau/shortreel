import json
import sys
from pathlib import Path

import laya_coreml as laya
from laya_coreml.inputs import collate_items

package = Path(__file__).resolve().parents[1]
agent = laya.load(sys.argv[1], local_files_only=True)
cases = [
    dict(id="refund", state="The customer requests a refund of a duplicate payment.",
         question="Choose the customer's request.", options=[
             dict(id="refund", description="The customer wants their money returned."),
             dict(id="cancel", description="The customer wants to cancel a subscription."),
             dict(id="other", description="A different request.")]),
    dict(id="unicode", state="El cliente solicita un reembolso. 日本語の質問。 Café 👋",
         question="What does the customer want?", options=[
             dict(id="refund", description="A refund."),
             dict(id="other", description="Something else.")]),
    dict(id="mask", state="Literal <mask> text should not create answer slots.",
         question="Does the text contain a literal <mask> marker?", options=[
             dict(id="yes", description="Contains <mask>."),
             dict(id="no", description="Does not contain it.")]),
    dict(id="prefix-budget", state="The user says hello.",
         question="Identify the state. " * 40, options=[
             dict(id=f"option-{i}", description=f"Option {i}: " + "long description " * 40)
             for i in range(16)]),
]

for path in sorted((package.parent / "Tests/Fixtures/AccountOCR").glob("*.json")):
    f = json.loads(path.read_text())
    cases.append(dict(id=path.stem, expected=f["outcome"],
        question="What kind of screen is this?",
        state="\n".join(r["text"] for r in sorted(f["regions"], key=lambda r: (r["y"], r["x"]))),
        options=[dict(id=k, description=v) for k, v in [
            ("profile", "A social media profile page showing account information, a username, followers, or videos."),
            ("signed-out", "A login or sign-up screen asking the user to sign in or choose an account."),
            ("unknown", "A different screen or unreadable text.")]]))
results = []
for case in cases:
    q = {case["id"]: dict(type="choice", instructions=case["question"],
          criteria={o["id"]: o["description"] for o in case["options"]})}
    original_tokenizer = agent.tok
    segments = {}
    class RecordingTokenizer:
        def __getattr__(self, key):
            return getattr(original_tokenizer, key)
        def __call__(self, text, **kwargs):
            result = original_tokenizer(text, **kwargs)
            segments[text] = result["input_ids"]
            return result
    agent.tok = RecordingTokenizer()
    items, _ = agent.prepare(case["state"], q)
    agent.tok = original_tokenizer
    batch = collate_items(items, agent.tok.pad_token_id, shape=agent.shape)
    logits, _ = agent.forward(batch)
    result = agent.predict(case["state"], q)
    result = result["answers"][case["id"]]
    print(case["id"], result["choice"], case.get("expected", ""), result["probabilities"], flush=True)
    results.append(dict(**case, rowJSON=json.dumps(case, ensure_ascii=False), segments=segments, ids=items[0]["ids"], markers=items[0]["markers"],
                        paddedLength=int(batch["input_ids"].shape[1]),
                        logits=logits[0, :len(case["options"])].tolist(),
                        probabilities=result["probabilities"], choice=result["choice"]))
out = dict(sourceRevision="4619e0483f07adf39068532e85b42ec2347edb83",
           modelRevision="8139e9089273319512c730218903784074133187", cases=results)
(package / "Tests/SemanticIfTests/Fixtures/laya-reference.json").write_text(
    json.dumps(out, ensure_ascii=False, indent=2) + "\n")
