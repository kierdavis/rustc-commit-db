A database of Rust compiler versions and the git commit that they were built
from.

```
Usage:
	./commit-db.rb update [--force]
	./commit-db.rb list-valid CHANNEL
	./commit-db.rb lookup COMMIT
```

This is all scraped from [buildbot](https://buildbot.rust-lang.org/) with some
missing information added in [fixups]. Note that nightly information is not
available before March 2016. PRs accepted :-p.
