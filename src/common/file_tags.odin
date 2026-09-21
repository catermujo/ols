package common

import "core:odin/tokenizer"
import "core:strings"

has_ignore_file_tag :: proc(source: string) -> bool {
	tok: tokenizer.Tokenizer
	tokenizer.init(&tok, source, "", nil)

	for {
		token := tokenizer.scan(&tok)
		#partial switch token.kind {
		case .Package, .EOF:
			return false
		case .File_Tag:
			tag := strings.trim_space(token.text)
			if strings.has_prefix(tag, "#+ignore") &&
			   (len(tag) == len("#+ignore") ||
			    strings.is_space(rune(tag[len("#+ignore")])) || tag[len("#+ignore")] == ',') {
				return true
			}
		}
	}
}
