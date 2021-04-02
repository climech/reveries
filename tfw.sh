#!/usr/bin/env bash

set -o pipefail

APP_NAME=tfw
VERSION=development # overwritten on install
GPG="gpg"
which gpg2 &>/dev/null && GPG="gpg2"
export GPG_TTY="${GPG_TTY:-$(tty 2>/dev/null)}"
GPG_OPTS=( $GESTALT_GPG_OPTS "--quiet" "--yes" "--compress-algo=none" "--no-encrypt-to" )
[[ -n $GPG_AGENT_INFO || $GPG == "gpg2" ]] && GPG_OPTS+=( "--batch" "--use-agent" )

# Check which variant of `date` is present on the system.
date --version >/dev/null 2>&1 && DATE_VARIANT="GNU" || DATE_VARIANT="BSD"

# Check if XDG_DATA_HOME exists
[ -z "$XDG_DATA_HOME" ] && XDG_DATA_HOME="$HOME/.local/share"

CONFIG_DIR="${XDG_DATA_HOME}/$APP_NAME"
ENTRY_DIR="${XDG_DATA_HOME}/$APP_NAME/entries"
DATE_FORMAT="%c"

#
# BEGIN utils
#

log() {
	echo "$@" >&2
}

die() {
	[[ "$#" -gt 0 ]] && log "$@"
	exit 1
}

yesno() {
	local response
	read -p "$1 [Y/n] " response
	[ "$response" == "Y" ]
}

# Get current time in ISO 8601 basic format, e.g. "20210307T021732+0100".
get_current_iso8601_basic() {
	date +"%Y%m%dT%H%M%S%z"
}

iso8601_basic_to_extended() {
	# GNU/date doesn't provide a way to specify the input format, but we can use
	# some trickery to achieve the same effect. It even works for arbitrary-length
	# years!
	rev |
		awk 'BEGIN { OFS = ":" } ; {
			print substr($1,1,2), substr($1,3,5), substr($1,8,2), substr($1,10)
		}' |
		awk 'BEGIN { OFS = "-" } ; {
			print substr ($1,1,17), substr($1,18,2), substr($1,20)
		}' |
		rev
}

iso8601_extended_to_epoch() {
	if [[ $DATE_VARIANT == "GNU" ]]; then
		date -d "$(cat -)" +"%s"
	else
		# Remove ':' from UTC offset for '%z' to work.
		rev | sed 's/://' | rev | date -jf '%Y-%m-%dT%H:%M:%S%z' "$(cat -)" +"%s"
	fi
}

# Convert a date in the format "YYYY-MM-DD" to seconds since Unix Epoch.
date_to_epoch() {
	if [[ $DATE_VARIANT == "GNU" ]]; then
		date -d "$(cat -)" +"%s"
	else
		date -jf "%F" "$(cat -)" +"%s"
	fi
}

epoch_to_user_date() {
	if [[ $DATE_VARIANT == "GNU" ]]; then
		date -d "@$(cat -)" +"$DATE_FORMAT"
	else
		date -jf "%s" "$(cat -)" +"$DATE_FORMAT"
	fi
}

new_filename() {
	# The basic format can be safely used for filenames (no illegal characters).
	get_current_iso8601_basic | sed 's/$/.gpg/'
}

# Create a new directory in /dev/shm and set TMPDIR to its path. If /dev/shm is
# not available, use /tmp and shred the files on script exit.
new_tmpdir() {
	local template="$APP_NAME.XXXXXXXXXXXXX"

  if [[ -d /dev/shm && -w /dev/shm && -x /dev/shm ]]; then
    TMPDIR="$(mktemp -d "/dev/shm/$template")"
		trap "rm -rf $TMPDIR" EXIT
  else
    TMPDIR="$(mktemp -d "/tmp/$template")"

		if ! rm --version &> /dev/null; then
			remove_tmpdir() (
				# BSD/rm includes a `-P` option which is similar to shred.
				shopt -s nullglob
				for f in "$TMPDIR"/*; do
					rm -fP "$f"
				done
				rm -rf "$TMPDIR"
			)
			trap remove_tmpdir EXIT
		elif command -v shred &> /dev/null; then
			remove_tmpdir() (
				shopt -s nullglob
				for f in "$TMPDIR"/*; do
					shred -ufn 5 "$f"
				done
				rm -rf "$TMPDIR"
			)
			trap remove_tmpdir EXIT
		else
			log "Neither '/dev/shm' nor 'shred' was found on the system."
			log "Please install 'shred' and try again."
			return 1
		fi
  fi
}

printf_repeat() {
	local str="$1"
	local count="$2"
	for ((n=0;n<$count;n++)); do
		printf "$str"
	done
}

printf_cyan() {
	local c_start='\033[0;36m'
	local c_end='\033[0m'
	if [ -t 1 ]; then
		# Colored output for console.
		printf "${c_start}${1}${c_end}"
	else
		# No colors when used in a pipe.
		printf "$1"
	fi
}

#
# END utils
#

load_recipient_id() {
	local filename="$CONFIG_DIR/.gpg-id"
	RECIPIENT="$(cat 2>/dev/null <"$filename")" ||
		die "GPG key is not set. Run \`init\` to initialize the program."
}

RE_FILENAME='([0-9]+)([0-9]{2})([0-9]{2})T([0-9]{2})([0-9]{2})([0-9]{2})([+\-])([0-9]{2})([0-9]{2})\.gpg'

# Load the base names of the entry files.
load_entry_filenames() {
	FILENAMES=()
	shopt -s nullglob
	for f in "$ENTRY_DIR"/*; do
		if [[ -f "$f" && "$f" =~ ${RE_FILENAME}$ ]]; then
			FILENAMES+=("${BASH_REMATCH[0]}")
		fi
	done
}

# Fill the arrays: FILENAMES, EPOCHS, DATES.
load_entries() {
	local extended
	load_entry_filenames

	mapfile -t extended < <(for f in "${FILENAMES[@]}"; do \
		echo "$f" | sed 's/\.gpg$//' | iso8601_basic_to_extended; \
	done)

	mapfile -t EPOCHS < <(for e in "${extended[@]}"; do \
		printf "$e" | iso8601_extended_to_epoch; \
	done)

	mapfile -t DATES < <(for e in "${EPOCHS[@]}"; do \
		printf "$e" | epoch_to_user_date; \
	done)
}

#
# BEGIN selectors
#

SELECTION=()
RE_INDEX='(\-?[0-9]+)'
RE_DATE='([0-9]+)-([0-9]{2})-([0-9]{2})'

# is_selector() returns true if string looks like a selector (dates may still
# be invalid and need to be checked separately).
is_selector() {
	[[ "$1" =~ ^${RE_INDEX}$ || "$1" =~ ^(${RE_INDEX})?:(${RE_INDEX})?$ ||
	   "$1" =~ ^${RE_DATE}$ || "$1" =~ ^(${RE_DATE})?:(${RE_DATE})?$ ]]
}

is_valid_index() {
	[[ "$1" =~ ^${RE_INDEX}$ ]]
}

# sel() parses the selectors and calls the appropriate function. Selected entry
# indices are appended to $SELECTION. Dies on invalid selectors.
sel() {
	for s in "$@"; do
		if [[ "$s" =~ ^${RE_INDEX}$ ]]; then
			select_by_index "$s"
		elif [[ "$s" =~ ^${RE_DATE}$ ]]; then
			select_by_date "$s"
		elif [[ "$s" =~ ^(.*):(.*)$ ]]; then
			local a="${BASH_REMATCH[1]}"
			local b="${BASH_REMATCH[2]}"
			if [[ -z "$a" || "$a" =~ ^${RE_INDEX}$ ]] && \
			   [[ -z "$b" || "$b" =~ ^${RE_INDEX}$ ]]; then
				select_by_index_range "$a" "$b"
			elif [[ -z "$a" || "$a" =~ ^${RE_DATE}$ ]] && \
			     [[ -z "$b" || "$b" =~ ^${RE_DATE}$ ]]; then
				select_by_date_range "$a" "$b"
			else
				die "Invalid range: '$a:$b'"
			fi
		else
			die "Invalid selection: '$s'"
		fi
	done
	# Sort and remove duplicates.
	if [[ "${#SELECTION[@]}" -gt 0 ]]; then
		local IFS=$'\n'
		SELECTION=($(printf "%s\n" "${SELECTION[@]}" | sort -nu))
	fi
}

# index_selector_to_array_index() converts the human-friendly index to bash
# array index.
index_selector_to_array_index() {
	local i="$1"
	if [[ "$i" -lt 0 ]]; then
		i=$(( "${#FILENAMES[@]}" + 1 + "$i" ))
		[[ "$i" -lt 1 ]] && i=1
	fi
	echo $(( "$i" - 1 ))
}

# select_by_index() selects an entry by index selector. If entry referred to by
# the selector exists, the actual array index of the entry is appended to
# $SELECTION.
select_by_index() {
	local i="$1"
	i=$(index_selector_to_array_index "$1")
	if [[ $i -ge 0 && $i -lt "${#FILENAMES[@]}" ]]; then
		SELECTION+=($i)
	fi
}

# select_by_index_range() selects the entry filenames in the given index range.
select_by_index_range() {
	[[ "${#FILENAMES[@]}" -eq 0 ]] && return 0
	local min="$1"
	local max="$2"
	[[ -z "$min" ]] && min="1"  # first element by default
	[[ -z "$max" ]] && max="-1"  # last element by default

	min=$(index_selector_to_array_index "$min")
	max=$(index_selector_to_array_index "$max")

	local length=$(( "$max" - "$min" + 1 ))
	local indices=("${!FILENAMES[@]}")
	for i in "${indices[@]:$min:$length}"; do
		SELECTION+=($i)
	done
}

# select_by_date() selects entries by date selector. Dies on invalid dates.
select_by_date() {
	local min max
	min=$(printf "$1" | date_to_epoch) || die
	max=$(( $min + 24 * 60 * 60 ))

	for i in "${!EPOCHS[@]}"; do
		if [[ "${EPOCHS[$i]}" -ge $min && ${EPOCHS[$i]} -lt $max ]]; then
			SELECTION+=($i)
		fi
	done

	echo "SELECTION: ${SELECTION[@]}"
}

select_by_date_range() {
	local min max
	if [[ -z "$1" ]]; then
		min=${EPOCHS[0]}
	else
		min=$(printf "$1" | date_to_epoch) || die
	fi
	if [[ -z $2 ]]; then
		max=$(( ${EPOCHS[-1]} + 24 * 60 * 60 ))
	else
		max=$(printf "$2" | date_to_epoch) || die
		max=$(( $max + 24 * 60 * 60 ))
	fi
	for i in ${!EPOCHS[@]}; do
		if [[ ${EPOCHS[$i]} -ge $min && ${EPOCHS[$i]} -lt $max ]]; then
			SELECTION+=($i)
		fi
	done
}

#
# END selectors
#

reencrypt_file() {
	local filepath="$1"
	local gpgid="$2"
	local filename
	filename="$(basename "$filepath")" || return 1
	new_tmpdir || return 1

	cat "$filepath" |
		"$GPG" -d "${GPG_OPTS[@]}" |
		"$GPG" -o "$TMPDIR/$filename" "${GPG_OPTS[@]}" -er "$gpgid" || return 1

	cat "$TMPDIR/$filename" > "$filepath" || return 1
}

reencrypt_all() {
	local gpgid="$1"
	for f in "${FILENAMES[@]}"; do
		if ! reencrypt_file "$ENTRY_DIR/$f" "$gpgid"; then
			log "Couldn't re-encrypt file: $f"
			return 1
		fi
		log "Re-encrypted: $f"
	done
}

edit_file() {
	[[ -z "$EDITOR" ]] && die '$EDITOR is not set, aborting...'
	"$EDITOR" "$1"
}

# decrypt_file() decrypts and prints the file.
decrypt_file() {
	"$GPG" "${GPG_OPTS[@]}" -d "$1"
}

print_header() {
	local text="$1"
	printf_cyan "$text\n"
	printf_cyan "$(printf_repeat '=' ${#text})\n\n"
}

#
# BEGIN commands
#

# cmd_init() sets the receiver key and re-encrypts existing files.
cmd_init() {
	[[ "$#" -ne 1 ]] && die "Usage: $APP_NAME <gpg-id>"
	load_entries
	local gpgid="$1"
	local errmsg="Couldn't initialize $APP_NAME"
	# Ensure directories exist.
	mkdir -p "$ENTRY_DIR" || die "$errmsg."
	# Check if key exists.
	"$GPG" "${GPG_OPTS[@]}" --list-keys "$gpgid" > /dev/null 2>&1 ||
		die "$errmsg: key '$gpgid' does not exist."
	# Save id.
	echo "$gpgid" > "$CONFIG_DIR/.gpg-id" || die "$errmsg."
	# Re-encrypt existing entries.
	reencrypt_all "$gpgid" || die "$errmsg."
	log "$APP_NAME successfully initialized for $gpgid."
}

cmd_new() {
	load_recipient_id
	local filename
	new_tmpdir || die
	filename="$(new_filename)"
	edit_file "$TMPDIR/$filename"
	# Encrypt & save if file exists.
	if [[ -f "$TMPDIR/$filename" ]]; then
		cat "$TMPDIR/$filename" |
			"$GPG" -o "$ENTRY_DIR/$filename" "${GPG_OPTS[@]}" -er "$RECIPIENT"
	else 
		log "Nothing to encrypt, aborting..."
	fi
}

cmd_edit() {
	[[ "$#" -ne 1 ]] && die "Usage: $app_name edit <index>"
	! is_valid_index "$1" && die "index must be an integer"
	load_recipient_id
	load_entries
	select_by_index "$1"
	[[ "${#SELECTION[@]}" -ne 1 ]] && die "Index out of range."
	local i="${SELECTION[0]}"
	local filename="${FILENAMES[$i]}"
	new_tmpdir || die
	$GPG -o "$TMPDIR/$filename" --yes --quiet -d "$ENTRY_DIR/$filename" || die
	edit_file "$TMPDIR/$filename" || die
	cat "$TMPDIR/$filename" | $GPG -o "$ENTRY_DIR/$filename" --yes -er "$RECIPIENT"
}

cmd_list() {
	load_entries

	local selectors
	[[ "$#" -gt 0 ]] && selectors=("$@") || selectors=(":")
	sel "${selectors[@]}"

	local maxlen=0
	if [[ ${#SELECTION[@]} -gt 0 ]]; then
		maxlen=$(( ${#SELECTION[$(( ${#SELECTION[@]} - 1 ))]} + 2 ))
	fi

	for i in "${SELECTION[@]}"; do
		printf_cyan "$(printf "%-${maxlen}s " "$(($i+1)).")"
		printf "${DATES[$i]} "
		printf "\n"
	done 
}

cmd_cat() {
	[[ "$#" -eq 0 ]] && die "Usage: $APP_NAME cat <selector>..."
	load_entries
	sel "$@"
	[[ "${#SELECTION[@]}" -eq 0 ]] && die "No entries selected."
	local body
	for i in "${SELECTION[@]}"; do
		body="$(decrypt_file "$ENTRY_DIR/${FILENAMES[$i]}")" || die
		print_header "${DATES[$i]}"
		printf "$body\n\n"
	done
}

cmd_view() {
	[[ "$#" -eq 0 ]] && die "Usage: $APP_NAME view <selector>..."
	local text
	text="$(cmd_cat "$@")" || die
	local width=$(tput cols)
	[[ $width -gt 80 ]] && width=80
	printf "$text" | fold -w $width -s | less -R +1g
}

# cmd_remove() uses trash-cli if found otherwise permanently deletes selected entries.
# Prompts for confirmation when multiple entries are selected.
cmd_remove() {
	[[ "$#" -eq 0 ]] && die "Usage: $APP_NAME remove|rm <selector>..."

	load_entries
	sel "$@"
	local count="${#SELECTION[@]}"
	[[ $count -eq 0 ]] && die "No entries selected."
	if [[ $count -ge 2 ]]; then
		printf "%d entries selected for removal:\n\n" $count
		for i in "${SELECTION[@]}"; do
			printf "    * ${DATES[$i]} "
			printf_cyan $(printf "(%d)" $(( $i + 1 )))
			printf "\n"
		done
		printf "\n"
		yesno "Do you wish to proceed?" || die "Aborted."
	fi

  local TRASH_CMD="rm -f"
  which trash-put &> /dev/null &&
    TRASH_CMD="trash-put"

	for i in "${SELECTION[@]}"; do
		${TRASH_CMD} "$ENTRY_DIR/${FILENAMES[$i]}"
	done
}

cmd_grep() {
	[[ "$#" -eq 0 ]] && die "Usage: $APP_NAME grep <grep-args> [<selector>...]"
	load_entries

	# Isolate selectors by starting from the end of args and backing up as
	# long as the current arg looks like a selector.
	local args=("$@")
	local sel_start=${#args[@]}
	for (( i=$(( ${#args[@]} - 1 )); i>=0; i-- )); do
		! is_selector "${args[$i]}" && break
		sel_start=$(( $sel_start - 1 ))
	done
	local grep_args=("${args[@]:0:$sel_start}")
	local sel_args=("${args[@]:$sel_start}")

	# Select all, if no selectors.
	if [[ ${#sel_args[@]} -eq 0 ]]; then
		sel_args+=(":")
	fi

	sel "${sel_args[@]}"

	local grep_results
	local width=$(tput cols)
	[[ $width -gt 80 ]] && width=80
	for i in "${SELECTION[@]}"; do
		grep_results="$( \
			decrypt_file "$ENTRY_DIR/${FILENAMES[$i]}" | \
			fold -sw $width | \
			grep --color=always "${grep_args[@]}" -)"

		if [ ! -z "$grep_results" ]; then
			printf_cyan $(($i + 1))": ${DATES[$i]}:\n"
			echo "$grep_results"
		fi
	done
}

cmd_version() {
	[[ "$#" -ne 0 ]] && die "Usage: $APP_NAME version|-v|--version"
	echo "$APP_NAME $VERSION"
}

cmd_help() {
	[[ "$#" -ne 0 ]] && die "Usage: $APP_NAME help|-h|--help"
	cat <<-HELPDOC
		Usage: tfw <command> [<args>]

		Commands:

		    new          create a new entry
		    cat          decrypt and print selected entries
		    edit         edit entry
		    grep         use grep on selected entries
		    help         print this text and exit
		    init         initialize the program with GPG id
		    list|ls      list selected entries
		    remove|rm    remove selected entries
		    version      print version
		    view         decrypt and view selected entries in \`less\`

	HELPDOC
}

#
# END commands
#

main() {
	local cmd
	if [[ "$#" -gt 0 ]]; then
		cmd="$1"
		shift
	fi
	case "$cmd" in
		new|"") cmd_new "$@";;
		cat) cmd_cat "$@";;
		edit) cmd_edit "$@";;
		grep) cmd_grep "$@";;
		help|-h|--help) cmd_help "$@";;
		init) cmd_init "$@";;
		list|ls) cmd_list "$@";;
		remove|rm) cmd_remove "$@";;
		version|-v|--version) cmd_version "$@";;
		view) cmd_view "$@";;
		*) echo "Invalid command: '$cmd'."
	esac
}

main "$@"
