import pf.Arbitrary
import pf.Fuzz
import pf.Target

## Keep the existing corpus format: every input is generator entropy, including
## inputs whose bytes resemble roc-fuzz's newer encoded-value envelope. Product
## types keep their own codecs; fuzzing does not require a binary codec for them.
EntropyTarget := [].{
	target_with : { name : Str, generator : Fuzz.Generator(a), test : a -> Fuzz.Outcome, show : a -> Str } -> Target
	target_with = |config| {
		generator = config.generator
		property = config.test
		show_value = config.show
		Target.new({
			name: config.name,
			example_count: || 0,
			example: |_| crash "entropy target declares no saved examples",
			run!: |bytes| match property(generator(Arbitrary.new(bytes)).value) {
				Keep => 0
				Reject => 1
			},
			show: |bytes| show_value(generator(Arbitrary.new(bytes)).value),
		})
	}
}
