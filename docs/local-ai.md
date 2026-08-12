# A local model, kept honest

The assistant runs on the machine: an 8B model served by Ollama on the integrated GPU. Voice
in through Whisper, out through Piper. No prompt, no receipt, no financial figure leaves the
house.

That choice costs capability. An 8B model is not a frontier model, and pretending otherwise
produces a confident liar attached to real data. Most of the interesting work is the
guardrails.

## Tools, not free-form recall

The model does not answer from memory about the house. It calls tools that return structured
data: what the bills are, what the calendar says, what is in the inventory, what the sensors
report. The system prompt is explicit that answers must come only from fields present in the
tool result.

That alone was not enough.

## Four failures, and what each one taught

**It reordered a ranking.** Asked for the most listened artists of a year, it returned a list
in an order that was not the data's order. Fix: the tool sorts server-side and the field is
named `by_year_most_listened_first`. If the ordering matters, it must not be the model's job.

**It invented a purchase date.** Reading a receipt, it filled in today's date for an item
bought months earlier, which is exactly the plausible-looking error that survives review. Fix:
a date is accepted only if the string appears literally in the extracted text. The model can
suggest; it cannot originate a fact.

**It made up listening statistics.** Same class of problem as the ranking: when a tool result
is thin, a small model fills the gap with something shaped like an answer. Fix: explicit
instruction not to answer beyond the fields returned, and tools that return empty rather than
approximate.

**It was slow for a boring reason.** Receipt reading took 25 seconds. The model was spending
344 thinking tokens to produce a 74-token JSON object. Setting `format: json` and disabling
the thinking phase brought it to 5 seconds. Keeping the model warm removed the rest.

## Reading receipts without sending them anywhere

Adding an appliance to the house inventory accepts a PDF or a photo of the invoice. Text comes
out with `pdftotext` when the PDF has a text layer, and Tesseract when it does not. The model
turns that text into fields: product, model, purchase date, warranty.

Invoices often list several items. The reader returns all of them, the interface offers them
as choices, and each selection becomes its own record while keeping the link to the same
receipt file.

A rejected upload deletes its file. The server-side rule is stricter than the interface: the
endpoint refuses to delete a receipt still referenced by a record. That rule exists because I
once deleted a real invoice while cleaning up test uploads, and had to recover it from the
file server's trash.

## What running locally actually buys

Not privacy in the abstract. Concretely: the receipts are invoices with addresses on them, the
financial tool reads real balances, and the calendar has other people's names in it. None of
that is interesting enough to justify sending it to an API, and the moment it leaves the
machine it stops being mine.

The cost is real too, and worth stating plainly: the model is smaller, occasionally wrong in
ways a larger one would not be, and every guardrail above exists because of a specific
failure. That is the trade, made with open eyes.
