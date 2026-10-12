"""The "summarize" task, executed by LangGraph (optional; needs
`pip install langgraph langgraph-checkpoint-sqlite`).

How this fits the protocol (spec section 7, "the protocol carries state, not
behaviour"):

  * The PROTOCOL still owns step bookkeeping: it mints the idempotency key,
    tags the step (I1), appends to the log (I4) and applies the result (I2).
    That code is unchanged. This class only replaces "how one step is done".
  * Cross-device state is still the neutral JSON TaskState. LangGraph's own
    checkpoint format never leaves this machine and the phone never sees it.
  * One protocol step = one run of a small graph:

        prepare (build the prompt) -> generate (call the model) -> clean

    The graph is checkpointed to SQLite with thread_id = the step's
    idempotency key. So on THIS machine, re-running a step under the same key
    (after a crash or a failed model call) resumes from the last finished node
    instead of starting over, and a step that already finished returns its
    stored result without calling the model again.
  * That does NOT make the step exactly-once across devices. A step the phone
    started has no checkpoint here, so it runs fresh and the two results can
    still differ (the divergence check is unchanged).

`apply_result` and `final_result` are delegated to the plain SummarizeTask so
the stored task content cannot differ between the two implementations.
"""
import os
import sqlite3
from typing import Any, Dict, Optional, TypedDict

from langgraph.checkpoint.sqlite import SqliteSaver
from langgraph.graph import END, START, StateGraph


class _StepState(TypedDict, total=False):
    step: int
    total: int
    chunk: str
    running: str
    prompt: str
    raw: str
    summary: str


class LangGraphSummarizeTask:
    task_type = "summarize"

    def __init__(self, rx: Any, endpoint: str, model: str, db_path: str):
        """`rx` is the receiver module (build_summary_prompt, clean_summary,
        ollama_generate, SummarizeTask). Passed in to avoid importing the
        receiver twice when it is run as a script."""
        self.rx = rx
        self.endpoint, self.model = endpoint, model
        self._plain = rx.SummarizeTask(endpoint, model)
        self.model_calls = 0                    # for tests / logging
        os.makedirs(os.path.dirname(os.path.abspath(db_path)), exist_ok=True)
        self._conn = sqlite3.connect(db_path, check_same_thread=False)
        self.saver = SqliteSaver(self._conn)
        self.graph = self._build()

    # ---- the graph
    def _build(self):
        rx = self.rx

        def prepare(s: _StepState) -> Dict[str, Any]:
            return {"prompt": rx.build_summary_prompt(s["step"], s["total"], s["chunk"], s["running"])}

        def generate(s: _StepState) -> Dict[str, Any]:
            self.model_calls += 1
            return {"raw": rx.ollama_generate(self.endpoint, self.model, s["prompt"])}

        def clean(s: _StepState) -> Dict[str, Any]:
            return {"summary": rx.clean_summary(s["raw"])}

        g = StateGraph(_StepState)
        g.add_node("prepare", prepare)
        g.add_node("generate", generate)
        g.add_node("clean", clean)
        g.add_edge(START, "prepare")
        g.add_edge("prepare", "generate")
        g.add_edge("generate", "clean")
        g.add_edge("clean", END)
        return g.compile(checkpointer=self.saver)

    # ---- the handler interface used by TaskRunner
    def run_step(self, step: int, state: Dict[str, Any]) -> str:
        """Do step N. MUST NOT change `state`."""
        pa = state.get("pendingAction") or {}
        key = pa.get("idempotencyKey")
        if not key or pa.get("forStep") != step:
            raise RuntimeError("step is not tagged with an idempotency key (invariant I1)")
        data = state.get("data") or {}
        chunks = data.get("chunks") or []
        cfg = {"configurable": {"thread_id": key}}

        snap = self.graph.get_state(cfg)
        if snap.values and not snap.next and snap.values.get("summary") is not None:
            return snap.values["summary"]                       # finished earlier under this key
        if snap.values and snap.next:
            out = self.graph.invoke(None, cfg)                  # resume at the unfinished node
        else:
            out = self.graph.invoke({
                "step": step, "total": state["targetStep"],
                "chunk": chunks[step - 1] if len(chunks) >= step else "",
                "running": data.get("runningSummary", "") or ""}, cfg)
        return out["summary"]

    def apply_result(self, step: int, result: str, state: Dict[str, Any]) -> None:
        self._plain.apply_result(step, result, state)

    def final_result(self, state: Dict[str, Any], device_id: str) -> Dict[str, Any]:
        return self._plain.final_result(state, device_id)

    def close(self) -> None:
        self._conn.close()
