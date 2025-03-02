;;; erc-fill.el --- Filling IRC messages in various ways  -*- lexical-binding: t; -*-

;; Copyright (C) 2001-2004, 2006-2023 Free Software Foundation, Inc.

;; Author: Andreas Fuchs <asf@void.at>
;;         Mario Lang <mlang@delysid.org>
;; Maintainer: Amin Bandali <bandali@gnu.org>, F. Jason Park <jp@neverwas.me>
;; URL: https://www.emacswiki.org/emacs/ErcFilling

;; This file is part of GNU Emacs.

;; GNU Emacs is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; GNU Emacs is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; This package implements filling of messages sent and received.  Use
;; `erc-fill-mode' to switch it on.  Customize `erc-fill-function' to
;; change the style.

;; TODO: redo `erc-fill-wrap-nudge' using transient after ERC drops
;; support for Emacs 27.

;;; Code:

(require 'erc)
(require 'erc-stamp); for the timestamp stuff

(defgroup erc-fill nil
  "Filling means to reformat long lines in different ways."
  :group 'erc)

;;;###autoload(autoload 'erc-fill-mode "erc-fill" nil t)
(define-erc-module fill nil
  "Manage filling in ERC buffers.
ERC fill mode is a global minor mode.  When enabled, messages in
the channel buffers are filled."
  ;; FIXME ensure a consistent ordering relative to hook members from
  ;; other modules.  Ideally, this module's processing should happen
  ;; after "morphological" modifications to a message's text but
  ;; before superficial decorations.
  ((add-hook 'erc-insert-modify-hook #'erc-fill 60)
   (add-hook 'erc-send-modify-hook #'erc-fill 60))
  ((remove-hook 'erc-insert-modify-hook #'erc-fill)
   (remove-hook 'erc-send-modify-hook #'erc-fill)))

(defcustom erc-fill-prefix nil
  "Values used as `fill-prefix' for `erc-fill-variable'.
nil means fill with space, a string means fill with this string."
  :type '(choice (const nil) string))

(defcustom erc-fill-function 'erc-fill-variable
  "Function to use for filling messages.

Variable Filling with an `erc-fill-prefix' of nil:

<shortnick> this is a very very very long message with no
	    meaning at all

Variable Filling with an `erc-fill-prefix' of four spaces:

<shortnick> this is a very very very long message with no
    meaning at all

Static Filling with `erc-fill-static-center' of 27:

		<shortnick> foo bar baz
	 <a-very-long-nick> foo bar baz quuuuux
		<shortnick> this is a very very very long message with no
			    meaning at all

These two styles are implemented using `erc-fill-variable' and
`erc-fill-static'.  You can, of course, define your own filling
function.  Narrowing to the region in question is in effect while your
function is called.

A third style resembles static filling but \"wraps\" instead of
fills, thanks to `visual-line-mode' mode, which ERC automatically
enables when this option is `erc-fill-wrap' or when the module
`fill-wrap' is active.  Use `erc-fill-static-center' to specify
an initial \"prefix\" width and `erc-fill-wrap-margin-width'
instead of `erc-fill-column' for influencing initial message
width.  For adjusting these during a session, see the commands
`erc-fill-wrap-nudge' and `erc-fill-wrap-refill-buffer'.  Read
more about this style in the doc string for `erc-fill-wrap-mode'."
  :type '(choice (const :tag "Variable Filling" erc-fill-variable)
                 (const :tag "Static Filling" erc-fill-static)
                 (const :tag "Dynamic word-wrap" erc-fill-wrap)
                 function))

(defcustom erc-fill-static-center 27
  "Number of columns to \"outdent\" the first line of a message.
During early message handing, ERC prepends a span of
non-whitespace characters to every message, such as a bracketed
\"<nickname>\" or an `erc-notice-prefix'.  The
`erc-fill-function' variants `erc-fill-static' and
`erc-fill-wrap' look to this option to determine the amount of
padding to apply to that portion until the filled (or wrapped)
message content aligns with the indicated column.  See also
https://en.wikipedia.org/wiki/Hanging_indent."
  :type 'integer)

(defcustom erc-fill-variable-maximum-indentation 17
  "Don't indent a line after a long nick more than this many characters.
Set to nil to disable."
  :type '(choice (const :tag "Disable" nil)
                 integer))

(defcustom erc-fill-column 78
  "The column at which a filled paragraph is broken."
  :type 'integer)

(defcustom erc-fill-wrap-margin-width nil
  "Starting width in columns of dedicated stamp margin.
When nil, ERC normally pretends its value is one column greater
than the `string-width' of the formatted `erc-timestamp-format'.
However, when `erc-fill-wrap-margin-side' is `left' or
\"resolves\" to `left', ERC uses the width of the prompt if it's
wider on MOTD's end, which really only matters when `erc-prompt'
is a function."
  :package-version '(ERC . "5.6")
  :type '(choice (const nil) integer))

(defcustom erc-fill-wrap-margin-side nil
  "Margin side to use with `erc-fill-wrap-mode'.
A value of nil means ERC should decide based on the value of
`erc-insert-timestamp-function', which does not work for
user-defined functions."
  :package-version '(ERC . "5.6")
  :type '(choice (const nil) (const left) (const right)))

(defcustom erc-fill-wrap-align-prompt nil
  "Whether to align the prompt at the common `wrap-prefix'."
  :package-version '(ERC . "5.6")
  :type 'boolean)

(defcustom erc-fill-line-spacing nil
  "Extra space between messages on graphical displays.
Its value should be larger than that of the variable
`line-spacing', if set.  When unsure, start with 0.5."
  :package-version '(ERC . "5.6")
  :type '(choice (const nil) number))

(defvar-local erc-fill--function nil
  "Internal copy of `erc-fill-function'.
Takes precedence over the latter when non-nil.")

;;;###autoload
(defun erc-fill ()
  "Fill a region using the function referenced in `erc-fill-function'.
You can put this on `erc-insert-modify-hook' and/or `erc-send-modify-hook'."
  (unless (erc-string-invisible-p (buffer-substring (point-min) (point-max)))
    (when (or erc-fill--function erc-fill-function)
      ;; skip initial empty lines
      (goto-char (point-min))
      ;; Note the following search pattern was altered in 5.6 to adapt
      ;; to a change in Emacs regexp behavior that turned out to be a
      ;; regression (which has since been fixed).  The patterns appear
      ;; to be equivalent in practice, so this was left as is (wasn't
      ;; reverted) to avoid additional git-blame(1)-related churn.
      (while (and (looking-at (rx bol (* (in " \t")) eol))
                  (zerop (forward-line 1))))
      (unless (eobp)
        (save-restriction
          (narrow-to-region (point) (point-max))
          (funcall (or erc-fill--function erc-fill-function))
          (when-let ((erc-fill-line-spacing)
                     (p (point-min)))
            (widen)
            (when (or (erc--check-msg-prop 'erc-msg 'msg)
                      (and-let* ((m (save-excursion
                                      (forward-line -1)
                                      (erc--get-inserted-msg-prop 'erc-msg))))
                        (eq 'msg m)))
              (put-text-property (1- p) p
                                 'line-spacing erc-fill-line-spacing))))))))

(defun erc-fill-static ()
  "Fills a text such that messages start at column `erc-fill-static-center'."
  (save-restriction
    (goto-char (point-min))
    (when-let (((looking-at "^\\(\\S-+\\)"))
               ((not (erc--check-msg-prop 'erc-msg 'datestamp)))
               (nick (match-string 1)))
      (progn
        (let ((fill-column (- erc-fill-column (erc-timestamp-offset)))
              (fill-prefix (make-string erc-fill-static-center 32)))
          (insert (make-string (max 0 (- erc-fill-static-center
                                         (length nick) 1))
                               32))
          (erc-fill-regarding-timestamp))
        (erc-restore-text-properties)))))

(defun erc-fill-variable ()
  "Fill from `point-min' to `point-max'."
  (let ((fill-prefix erc-fill-prefix)
        (fill-column (or erc-fill-column fill-column)))
    (goto-char (point-min))
    (if fill-prefix
        (let ((first-line-offset (make-string (erc-timestamp-offset) 32)))
          (insert first-line-offset)
          (fill-region (point-min) (point-max) t t)
          (goto-char (point-min))
          (delete-char (length first-line-offset)))
      (save-match-data
        (let* ((nickp (looking-at "^\\(\\S-+\\)"))
               (nick (if nickp
                         (match-string 1)
                       ""))
               (fill-column (- erc-fill-column (erc-timestamp-offset)))
               (fill-prefix (make-string (min (+ 1 (length nick))
                                              (- fill-column 1)
                                              (or erc-fill-variable-maximum-indentation
                                                  fill-column))
                                         32)))
          (erc-fill-regarding-timestamp))))
    (erc-restore-text-properties)))

(defvar-local erc-fill--wrap-value nil)
(defvar-local erc-fill--wrap-visual-keys nil)

(defvar erc-fill-wrap-use-pixels t
  "Whether to calculate padding in pixels when possible.
A value of nil means ERC should use columns, which may happen
regardless, depending on the Emacs version.  This option only
matters when `erc-fill-wrap-mode' is enabled.")

(defcustom erc-fill-wrap-visual-keys 'non-input
  "Whether to retain keys defined by `visual-line-mode'.
A value of t tells ERC to use movement commands defined by
`visual-line-mode' everywhere in an ERC buffer along with visual
editing commands in the input area.  A value of nil means to
never do so.  A value of `non-input' tells ERC to act like the
value is nil in the input area and t elsewhere.  See related
option `erc-fill-wrap-force-screen-line-movement' for behavior
involving `next-line' and `previous-line'."
  :package-version '(ERC . "5.6")
  :type '(choice (const nil) (const t) (const non-input)))

(defcustom erc-fill-wrap-force-screen-line-movement '(non-input)
  "Exceptions for vertical movement by logical line.
Including a symbol known to `erc-fill-wrap-visual-keys' in this
set tells `next-line' and `previous-line' to move vertically by
screen line even if the current `erc-fill-wrap-visual-keys' value
would normally do otherwise.  For example, setting this to
\\='(nil non-input) disables logical-line movement regardless of
the value of `erc-fill-wrap-visual-keys'."
  :package-version '(ERC . "5.6")
  :type '(set (const nil) (const non-input)))

(defcustom erc-fill-wrap-merge t
  "Whether to consolidate consecutive messages from the same speaker.
When non-nil, ERC omits redundant speaker labels for subsequent
messages less than a day apart.  To help distinguish between
merged messages, see related options `erc-fill-line-spacing', for
graphical displays, and `erc-fill-wrap-merge-indicator' for text
terminals."
  :package-version '(ERC . "5.6")
  :type 'boolean)

(defface erc-fill-wrap-merge-indicator-face
  '((((min-colors 88) (background light)) :foreground "Gray")
    (((min-colors 16) (background light)) :foreground "LightGray")
    (((min-colors 16) (background dark)) :foreground "DimGray")
    (t :inherit shadow))
  "ERC `fill-wrap' merge-indicator face."
  :group 'erc-faces)

(defcustom erc-fill-wrap-merge-indicator nil
  "Indicator to help distinguish between merged messages.
Only matters when the option `erc-fill-wrap-merge' is enabled.
If the first element is the symbol `pre', ERC uses this option to
generate a replacement for the speaker's name tag.  If the first
element is `post', ERC affixes a short string to the end of the
previous message.  (Note that the latter variant nullifies any
intervening padding supplied by `erc-fill-line-spacing' and is
meant to supplant that option in text terminals.)  In either
case, the second element should be a character, like ?>, and the
last element a valid face.  In special cases, you may also
specify a cons of `pre'/`post' and a string, which tells ERC you
know what you're doing and not to manage the process for you.  If
unsure, try either of the first two presets, both of which
replace a continued speaker's name with a dot-product-like glyph
in `shadow' face.  Note that this option is still experimental,
and changing its value mid-session is not yet supported (though,
if you must, make sure to run \\[erc-fill-wrap-refill-buffer]
afterward)."
  :package-version '(ERC . "5.6")
  :type
  '(choice (const nil)
           (const :tag "Leading MIDDLE DOT (U+00B7) as speaker"
                  (pre #xb7 erc-fill-wrap-merge-indicator-face))
           (const :tag "Leading MIDDLE DOT (U+00B7) sans gap"
                  (pre . #("\u00b7" 0 1 (font-lock-face
                                         erc-fill-wrap-merge-indicator-face))))
           (const :tag "Leading RIGHT-ANGLE BRACKET (>) as speaker"
                  (pre ?> erc-fill-wrap-merge-indicator-face))
           (const :tag "Trailing PARAGRAPH SIGN (U+00B6)"
                  (post #xb6 erc-fill-wrap-merge-indicator-face))
           (const :tag "Trailing TILDE (~)"
                  (post ?~ erc-fill-wrap-merge-indicator-face))
           (cons :tag "User-provided string (advanced)"
                 (choice (const pre) (const post)) string)
           (list :tag "User-provided character-face pairing"
                 (choice (const pre) (const post)) character face)))

(defun erc-fill--wrap-move (normal-cmd visual-cmd &rest args)
  (apply (pcase erc-fill--wrap-visual-keys
           ('non-input
            (if (>= (point) erc-input-marker) normal-cmd visual-cmd))
           ('t visual-cmd)
           (_ normal-cmd))
         args))

(defun erc-fill--wrap-kill-line (arg)
  "Defer to `kill-line' or `kill-visual-line'."
  (interactive "P")
  ;; ERC buffers are read-only outside of the input area, but we run
  ;; `kill-line' anyway so that users can see the error.
  (erc-fill--wrap-move #'kill-line #'kill-visual-line arg))

(defun erc-fill--wrap-escape-hidden-speaker ()
  "Move to start of message text when left of speaker.
Basically mimic what `move-beginning-of-line' does with invisible text."
  (when-let ((erc-fill-wrap-merge)
             (prop (get-text-property (point) 'display))
             ((or (equal prop "") (eq 'margin (car-safe (car-safe prop))))))
    (goto-char (text-property-not-all (point) (pos-eol) 'display prop))))

(defun erc-fill--wrap-beginning-of-line (arg)
  "Defer to `move-beginning-of-line' or `beginning-of-visual-line'."
  (interactive "^p")
  (let ((inhibit-field-text-motion t))
    (erc-fill--wrap-move #'move-beginning-of-line
                         #'beginning-of-visual-line arg))
  (if (get-text-property (point) 'erc-prompt)
      (goto-char erc-input-marker)
    ;; Mimic what `move-beginning-of-line' does with invisible text.
    (erc-fill--wrap-escape-hidden-speaker)))

(defun erc-fill--wrap-previous-line (&optional arg try-vscroll)
  "Move to ARGth previous logical or screen line."
  (interactive "^p\np")
  ;; Return value seems undefined but preserve anyway just in case.
  (prog1
      (let ((visp (memq erc-fill--wrap-visual-keys
                        erc-fill-wrap-force-screen-line-movement)))
        (erc-fill--wrap-move (if visp #'previous-line #'previous-logical-line)
                             #'previous-line
                             arg try-vscroll))
    (erc-fill--wrap-escape-hidden-speaker)))

(defun erc-fill--wrap-next-line (&optional arg try-vscroll)
  "Move to ARGth next logical or screen line."
  (interactive "^p\np")
  (let ((visp (memq erc-fill--wrap-visual-keys
                    erc-fill-wrap-force-screen-line-movement)))
    (erc-fill--wrap-move (if visp #'next-line #'next-logical-line)
                         #'next-line
                         arg try-vscroll)))

(defun erc-fill--wrap-end-of-line (arg)
  "Defer to `move-end-of-line' or `end-of-visual-line'."
  (interactive "^p")
  (erc-fill--wrap-move #'move-end-of-line #'end-of-visual-line arg))

(defun erc-fill-wrap-cycle-visual-movement (arg)
  "Cycle through `erc-fill-wrap-visual-keys' styles ARG times.
Go from nil to t to `non-input' and back around, but set internal
state instead of mutating `erc-fill-wrap-visual-keys'.  When ARG
is 0, reset to value of `erc-fill-wrap-visual-keys'."
  (interactive "^p")
  (when (zerop arg)
    (setq erc-fill--wrap-visual-keys erc-fill-wrap-visual-keys))
  (while (not (zerop arg))
    (cl-incf arg (- (abs arg)))
    (setq erc-fill--wrap-visual-keys (pcase erc-fill--wrap-visual-keys
                                       ('nil t)
                                       ('t 'non-input)
                                       ('non-input nil))))
  (message "erc-fill-wrap movement: %S" erc-fill--wrap-visual-keys))

(defun erc-fill-wrap-toggle-truncate-lines (arg)
  "Toggle `truncate-lines' and maybe reinstate `visual-line-mode'."
  (interactive "P")
  (let ((wantp (if arg
                   (natnump (prefix-numeric-value arg))
                 (not truncate-lines)))
        (buffer (current-buffer)))
    (if wantp
        (setq truncate-lines t)
      (walk-windows (lambda (window)
                      (when (eq buffer (window-buffer window))
                        (set-window-hscroll window 0)))
                    nil t)
      (visual-line-mode +1)))
  (force-mode-line-update))

(defvar-keymap erc-fill-wrap-mode-map ; Compat 29
  :doc "Keymap for ERC's `fill-wrap' module."
  :parent visual-line-mode-map
  "<remap> <kill-line>" #'erc-fill--wrap-kill-line
  "<remap> <move-end-of-line>" #'erc-fill--wrap-end-of-line
  "<remap> <move-beginning-of-line>" #'erc-fill--wrap-beginning-of-line
  "<remap> <toggle-truncate-lines>" #'erc-fill-wrap-toggle-truncate-lines
  "<remap> <next-line>" #'erc-fill--wrap-next-line
  "<remap> <previous-line>" #'erc-fill--wrap-previous-line
  "C-c a" #'erc-fill-wrap-cycle-visual-movement
  ;; Not sure if this is problematic because `erc-bol' takes no args.
  "<remap> <erc-bol>" #'erc-fill--wrap-beginning-of-line)

(defvar erc-button-mode)
(defvar erc-legacy-invisible-bounds-p)

(defun erc-fill--wrap-ensure-dependencies ()
  (with-suppressed-warnings ((obsolete erc-legacy-invisible-bounds-p))
    (when erc-legacy-invisible-bounds-p
      (erc--warn-once-before-connect  'erc-fill-wrap-mode
        "Module `fill-wrap' is incompatible with the obsolete compatibility"
        " flag `erc-legacy-invisible-bounds-p'.  Disabling locally in %s."
        (current-buffer))
      (setq-local erc-legacy-invisible-bounds-p nil)))
  (let (missing-deps)
    (unless erc-fill-mode
      (push 'fill missing-deps)
      (erc-fill-mode +1))
    (when erc-fill-wrap-merge
      (require 'erc-button)
      (unless erc-button-mode
        (push 'button missing-deps)
        (erc-button-mode +1))
      (require 'erc-stamp)
      (unless erc-stamp-mode
        (push 'stamp missing-deps)
        (erc-stamp-mode +1)))
    (when missing-deps
      (erc--warn-once-before-connect 'erc-fill-wrap-mode
        "Enabling missing global modules %s needed by local"
        " module `fill-wrap'. This will impact \C-]all\C-] ERC"
        " sessions. Add them to `erc-modules' to avoid this"
        " warning. See Info:\"(erc) Modules\" for more."
        (mapcar (lambda (s) (format "`%s'" s)) missing-deps)))))

;;;###autoload(put 'fill-wrap 'erc--feature 'erc-fill)
(define-erc-module fill-wrap nil
  "Fill style leveraging `visual-line-mode'.
This module displays nicks overhanging leftward to a common
offset, as determined by the option `erc-fill-static-center'.
And it \"wraps\" messages at a common margin width, as determined
by the option `erc-fill-wrap-margin-width'.  To use it, either
include `fill-wrap' in `erc-modules' or set `erc-fill-function'
to `erc-fill-wrap'.  Most users will want to enable the
`scrolltobottom' module as well.

During sessions in which this module is active, use
\\[erc-fill-wrap-nudge] to adjust the width of the indent and the
stamp margin, and use \\[erc-fill-wrap-toggle-truncate-lines] for
cycling between logical- and screen-line oriented command
movement.  Similarly, use \\[erc-fill-wrap-refill-buffer] to fix
alignment problems after running certain commands, like
`text-scale-adjust'.  Also see related stylistic options
`erc-fill-line-spacing', `erc-fill-wrap-merge', and
`erc-fill-wrap-merge-indicator'.  Hint: in narrow windows, where
is space tight, try setting `erc-fill-static-center' to 1.  And
if you also use the option `erc-fill-wrap-merge-indicator', set
that to value-menu item \"Leading MIDDLE DOT (U+00B7) sans gap\"
or one of the various \"trailing\" items.

This module imposes various restrictions on the appearance of
timestamps.  Most notably, it insists on displaying them in the
margins.  Users preferring left-sided stamps may notice that ERC
also displays the prompt in the left margin, possibly truncating
or padding it to constrain it to the margin's width.
Additionally, this module assumes that users providing their own
`erc-insert-timestamp-function' have also customized the option
`erc-fill-wrap-margin-side' to an explicit side.  When stamps
appear in the right margin, which they do by default, users may
find that ERC actually appends them to copy-as-killed messages
without an intervening space.  This normally poses at most a
minor inconvenience, however users of the `log' module may prefer
a workaround provided by `erc-stamp-prefix-log-filter', which
strips trailing stamps from logged messages and instead prepends
them to every line.

As a so-called \"local\" module, `fill-wrap' depends on the
global modules `fill', `stamp', and `button'; it activates them
as needed when initializing.  Please note that enabling and
disabling this module by invoking one of its minor-mode toggles
is not recommended."
  ((erc-fill--wrap-ensure-dependencies)
   (erc--restore-initialize-priors erc-fill-wrap-mode
     erc-fill--wrap-visual-keys erc-fill-wrap-visual-keys
     erc-fill--wrap-value erc-fill-static-center
     erc-stamp--margin-width erc-fill-wrap-margin-width
     left-margin-width left-margin-width
     right-margin-width right-margin-width)
   (setq erc-stamp--margin-left-p
         (or (eq erc-fill-wrap-margin-side 'left)
             (eq (default-value 'erc-insert-timestamp-function)
                 #'erc-insert-timestamp-left)))
   (when erc-fill-wrap-align-prompt
     (add-hook 'erc--refresh-prompt-hook
               #'erc-fill--wrap-indent-prompt nil t))
   (when erc-stamp--margin-left-p
     (if erc-fill-wrap-align-prompt
         (setq erc-stamp--skip-left-margin-prompt-p t)
       (setq erc--inhibit-prompt-display-property-p t)))
   (setq erc-fill--function #'erc-fill-wrap)
   (when erc-fill-wrap-merge
     (add-hook 'erc-button--prev-next-predicate-functions
               #'erc-fill--wrap-merged-button-p nil t))
   (erc-stamp--display-margin-mode +1)
   (visual-line-mode +1))
  ((visual-line-mode -1)
   (erc-stamp--display-margin-mode -1)
   (kill-local-variable 'erc-fill--wrap-value)
   (kill-local-variable 'erc-fill--function)
   (kill-local-variable 'erc-fill--wrap-visual-keys)
   (kill-local-variable 'erc-fill--wrap-last-msg)
   (kill-local-variable 'erc--inhibit-prompt-display-property-p)
   (kill-local-variable 'erc-fill--wrap-merge-indicator-pre)
   (kill-local-variable 'erc-fill--wrap-merge-indicator-post)
   (remove-hook 'erc--refresh-prompt-hook
                #'erc-fill--wrap-indent-prompt)
   (remove-hook 'erc-button--prev-next-predicate-functions
                #'erc-fill--wrap-merged-button-p t))
  'local)

(defvar-local erc-fill--wrap-length-function nil
  "Function to determine length of overhanging characters.
It should return an EXPR as defined by the Info node `(elisp)
Pixel Specification'.  This value should represent the width of
the overhang with all faces applied, including any enclosing
brackets (which are not normally fontified) and a trailing space.
It can also return nil to tell ERC to fall back to the default
behavior of taking the length from the first \"word\".  This
variable can be converted to a public one if needed by third
parties.")

(defvar-local erc-fill--wrap-last-msg nil)
(defvar erc-fill--wrap-max-lull (* 24 60 60))

(defun erc-fill--wrap-continued-message-p ()
  "Return non-nil when the current speaker hasn't changed.
That is, indicate whether the text just inserted is from the same
sender as that of the previous \"PRIVMSG\"."
  (and
   (not (erc--check-msg-prop 'erc-ephemeral))
   (progn ; preserve blame for now, unprogn on next major change
     (prog1
         (and-let*
             ((m (or erc-fill--wrap-last-msg
                     (setq erc-fill--wrap-last-msg (point-min-marker))
                     nil))
              ((< (1+ (point-min)) (- (point) 2)))
              (props (save-restriction
                       (widen)
                       (and-let*
                           (((eq 'msg (get-text-property m 'erc-msg)))
                            ((not (eq (get-text-property m 'erc-ctcp)
                                      'ACTION)))
                            ((not (invisible-p m)))
                            (spr (next-single-property-change m 'erc-speaker)))
                         (cons (get-text-property m 'erc-ts)
                               (get-text-property spr 'erc-speaker)))))
              (ts (pop props))
              (props)
              ((not (time-less-p (erc-stamp--current-time) ts)))
              ((time-less-p (time-subtract (erc-stamp--current-time) ts)
                            erc-fill--wrap-max-lull))
              ;; Assume presence of leading angle bracket or hyphen.
              (speaker (next-single-property-change (point-min) 'erc-speaker))
              ((not (erc--check-msg-prop 'erc-ctcp 'ACTION)))
              (nick (get-text-property speaker 'erc-speaker))
              ((erc-nick-equal-p props nick))))
       (set-marker erc-fill--wrap-last-msg (point-min))))))

(defun erc-fill--wrap-measure (beg end)
  "Return display spec width for inserted region between BEG and END.
Ignore any `invisible' props that may be present when figuring.
Expect the target region to be free of `line-prefix' and
`wrap-prefix' properties, and expect `display-line-numbers-mode'
to be disabled."
  (if (fboundp 'buffer-text-pixel-size)
      ;; `buffer-text-pixel-size' can move point!
      (save-excursion
        (save-restriction
          (narrow-to-region beg end)
          (let* ((buffer-invisibility-spec)
                 (rv (car (buffer-text-pixel-size))))
            (if erc-fill-wrap-use-pixels
                (if (zerop rv) 0 (list rv))
              (/ rv (frame-char-width))))))
    (- end beg)))

;; An escape hatch for third-party code expecting speakers of ACTION
;; messages to be exempt from `line-prefix'.  This could be converted
;; into a user option if users feel similarly.
(defvar erc-fill--wrap-action-dedent-p t
  "Whether to dedent speakers in CTCP \"ACTION\" lines.")

(defvar-local erc-fill--wrap-merge-indicator-pre nil)
(defvar-local erc-fill--wrap-merge-indicator-post nil)

;; To support `erc-fill-line-spacing' with the "post" variant, we'd
;; need to use a new "replacing" `display' spec value for each
;; insertion, and add a sentinel property alongside it atop every
;; affected newline, e.g., (erc-fill-eol-display START-POS), where
;; START-POS is the position of the newline in the replacing string.
;; Then, upon spotting this sentinel in `erc-fill' (and maybe
;; `erc-fill-wrap-refill-buffer'), we'd add `line-spacing' to the
;; corresponding `display' replacement, starting at START-POS.
(defun erc-fill--wrap-insert-merged-post ()
  "Add `display' property at end of previous line."
  (save-excursion
    (goto-char (point-min))
    (save-restriction
      (widen)
      (cl-assert (= ?\n (char-before (point))))
      (unless erc-fill--wrap-merge-indicator-post
        (let ((option (cdr erc-fill-wrap-merge-indicator)))
          (setq erc-fill--wrap-merge-indicator-post
                (if (stringp option)
                    (concat option
                            (and (not (string-suffix-p "\n" option)) "\n"))
                  (propertize (concat (string (car option)) "\n")
                              'font-lock-face (cadr option))))))
      (unless (eq (field-at-pos (- (point) 2)) 'erc-timestamp)
        (put-text-property (1- (point)) (point)
                           'display erc-fill--wrap-merge-indicator-post)))
    0))

(defun erc-fill--wrap-insert-merged-pre ()
  "Add `display' property in lieu of speaker."
  (if erc-fill--wrap-merge-indicator-post
      (progn
        (put-text-property (point-min) (point) 'display
                           (car erc-fill--wrap-merge-indicator-pre))
        (cdr erc-fill--wrap-merge-indicator-pre))
    (let* ((option (cdr erc-fill-wrap-merge-indicator))
           (s (if (stringp option)
                  (concat option)
                (concat (propertize (string (car option))
                                    'font-lock-face (cadr option))
                        " "))))
      (put-text-property (point-min) (point) 'display s)
      (cdr (setq erc-fill--wrap-merge-indicator-pre
                 (cons s (erc-fill--wrap-measure (point-min) (point))))))))

(defun erc-fill-wrap ()
  "Use text props to mimic the effect of `erc-fill-static'.
See `erc-fill-wrap-mode' for details."
  (unless erc-fill-wrap-mode
    (erc-fill-wrap-mode +1))
  (save-excursion
    (goto-char (point-min))
    (let ((len (or (and erc-fill--wrap-length-function
                        (funcall erc-fill--wrap-length-function))
                   (and-let* ((msg-prop (erc--check-msg-prop 'erc-msg))
                              ((not (eq msg-prop 'unknown))))
                     (when-let ((e (erc--get-speaker-bounds))
                                (b (pop e))
                                ((or erc-fill--wrap-action-dedent-p
                                     (not (erc--check-msg-prop 'erc-ctcp
                                                               'ACTION)))))
                       (goto-char e))
                     (skip-syntax-forward "^-")
                     (forward-char)
                     (cond ((eq msg-prop 'datestamp)
                            (when erc-fill--wrap-last-msg
                              (set-marker erc-fill--wrap-last-msg (point-min)))
                            (save-excursion
                              (goto-char (point-max))
                              (skip-chars-backward "\n")
                              (let ((beg (pos-bol)))
                                (insert " ")
                                (prog1 (erc-fill--wrap-measure beg (point))
                                  (delete-region (1- (point)) (point))))))
                           ((and erc-fill-wrap-merge
                                 (erc-fill--wrap-continued-message-p))
                            (put-text-property (point-min) (point)
                                               'display "")
                            (if erc-fill-wrap-merge-indicator
                                (pcase (car erc-fill-wrap-merge-indicator)
                                  ('pre (erc-fill--wrap-insert-merged-pre))
                                  ('post (erc-fill--wrap-insert-merged-post)))
                              0))
                           (t
                            (erc-fill--wrap-measure (point-min) (point))))))))
      (add-text-properties
       (point-min) (1- (point-max)) ; exclude "\n"
       `( line-prefix (space :width ,(if len
                                         `(- erc-fill--wrap-value ,len)
                                       'erc-fill--wrap-value))
          wrap-prefix (space :width erc-fill--wrap-value))))))

(defun erc-fill--wrap-indent-prompt ()
  "Recompute the `line-prefix' of the prompt."
  ;; Clear an existing `line-prefix' before measuring (bug#64971).
  (remove-text-properties erc-insert-marker erc-input-marker
                          '(line-prefix nil wrap-prefix nil))
  ;; Restoring window configuration seems to prevent unwanted
  ;; recentering reminiscent of `scrolltobottom'-related woes.
  (let ((c (and (get-buffer-window) (current-window-configuration)))
        (len (erc-fill--wrap-measure erc-insert-marker erc-input-marker)))
    (when c
      (set-window-configuration c))
    (put-text-property erc-insert-marker erc-input-marker
                       'line-prefix
                       `(space :width (- erc-fill--wrap-value ,len)))))

(defvar erc-fill--wrap-rejigger-last-message nil
  "Temporary working instance of `erc-fill--wrap-last-msg'.")

(defun erc-fill--wrap-rejigger-region (start finish on-next repairp)
  "Recalculate `line-prefix' from START to FINISH.
After refilling each message, call ON-NEXT with no args.  But
stash and restore `erc-fill--wrap-last-msg' before doing so, in
case this module's insert hooks run by way of the process filter.
With REPAIRP, destructively fill gaps and re-merge speakers."
  (goto-char start)
  (cl-assert (null erc-fill--wrap-rejigger-last-message))
  (setq erc-fill--wrap-merge-indicator-pre nil
        erc-fill--wrap-merge-indicator-post nil)
  (let (erc-fill--wrap-rejigger-last-message)
    (while-let
        (((< (point) finish))
         (beg (if (get-text-property (point) 'line-prefix)
                  (point)
                (next-single-property-change (point) 'line-prefix)))
         (val (get-text-property beg 'line-prefix))
         (end (text-property-not-all beg finish 'line-prefix val)))
      ;; If this is a left-side stamp on its own line.
      (remove-text-properties beg (1+ end) '(line-prefix nil wrap-prefix nil))
      (when-let ((repairp)
                 (dbeg (text-property-not-all beg end 'display nil))
                 ((get-text-property (1+ dbeg) 'erc-speaker))
                 (dval (get-text-property dbeg 'display))
                 ((equal "" dval)))
        (remove-text-properties
         dbeg (text-property-not-all dbeg end 'display dval) '(display)))
      (let* ((pos (if (eq 'date-left (get-text-property beg 'erc-stamp-type))
                      (field-beginning beg)
                    beg))
             (erc--msg-props (map-into (text-properties-at pos) 'hash-table))
             (erc-stamp--current-time (gethash 'erc-ts erc--msg-props)))
        (save-restriction
          (narrow-to-region beg (1+ end))
          (let ((erc-fill--wrap-last-msg erc-fill--wrap-rejigger-last-message))
            (erc-fill-wrap)
            (setq erc-fill--wrap-rejigger-last-message
                  erc-fill--wrap-last-msg))))
      (when on-next
        (funcall on-next))
      ;; Skip to end of message upon encountering accidental gaps
      ;; introduced by third parties (or bugs).
      (if-let (((/= ?\n (char-after end)))
               (next (erc--get-inserted-msg-bounds 'end beg)))
          (progn
            (cl-assert (= ?\n (char-after next)))
            (when repairp ; eol <= next
              (put-text-property end (pos-eol) 'line-prefix val))
            (goto-char next))
        (goto-char end)))))

(defun erc-fill-wrap-refill-buffer (repair)
  "Recalculate all `fill-wrap' prefixes in the current buffer.
With REPAIR, attempt to refresh \"speaker merges\", which may be
necessary after revealing previously hidden text with commands
like `erc-match-toggle-hidden-fools'."
  (interactive "P")
  (unless erc-fill-wrap-mode
    (user-error "Module `fill-wrap' not active in current buffer."))
  (save-excursion
    (with-silent-modifications
      (let* ((rep (make-progress-reporter
                   "Rewrap" 0 (line-number-at-pos erc-insert-marker) 1))
             (seen 0)
             (callback (lambda ()
                         (progress-reporter-update rep (cl-incf seen))
                         (accept-process-output nil 0.000001))))
        (erc-fill--wrap-rejigger-region (point-min) erc-insert-marker
                                        callback repair)
        (progress-reporter-done rep)))))

;; FIXME use own text property to avoid false positives.
(defun erc-fill--wrap-merged-button-p (point)
  (equal "" (get-text-property point 'display)))

(defun erc-fill--wrap-nudge (arg)
  (when (zerop arg)
    (setq arg (- erc-fill-static-center erc-fill--wrap-value)))
  (cl-incf erc-fill--wrap-value arg)
  arg)

(defun erc-fill-wrap-nudge (arg)
  "Adjust `erc-fill-wrap' by ARG columns.
Offer to repeat command in a manner similar to
`text-scale-adjust'.

   \\`=' Increase indentation by one column
   \\`-' Decrease indentation by one column
   \\`0' Reset indentation to the default
   \\`+' Shift margin boundary rightward by one column
   \\`_' Shift margin boundary leftward by one column
   \\`)' Reset the right margin to the default

Note that misalignment may occur when messages contain
decorations applied by third-party modules."
  (interactive "p")
  (unless erc-fill--wrap-value
    (cl-assert (not erc-fill-wrap-mode))
    (user-error "Minor mode `erc-fill-wrap-mode' disabled"))
  (unless (get-buffer-window)
    (user-error "Command called in an undisplayed buffer"))
  (let* ((total (erc-fill--wrap-nudge arg))
         (leftp erc-stamp--margin-left-p)
         ;; Anchor current line vertically.
         (line (count-screen-lines (window-start) (window-point))))
    (when (zerop arg)
      (setq arg 1))
    (erc-compat-call
     set-transient-map
     (let ((map (make-sparse-keymap)))
       (dolist (key '(?= ?- ?0))
         (let ((a (pcase key
                    (?0 0)
                    (?- (- (abs arg)))
                    (_ (abs arg)))))
           (define-key map (vector (list key))
                       (lambda ()
                         (interactive)
                         (cl-incf total (erc-fill--wrap-nudge a))
                         (recenter line)))))
       (dolist (key '(?\) ?_ ?+))
         (let ((a (pcase key
                    (?\) 0)
                    (?_ (if leftp (abs arg) (- (abs arg))))
                    (?+ (if leftp (- (abs arg)) (abs arg))))))
           (define-key map (vector (list key))
                       (lambda ()
                         (interactive)
                         (erc-stamp--adjust-margin (- a) (zerop a))
                         (when leftp (erc-stamp--refresh-left-margin-prompt))
                         (recenter line)))))
       map)
     t
     (lambda ()
       (message "Fill prefix: %d (%+d col%s); Margin: %d"
                erc-fill--wrap-value total (if (> (abs total) 1) "s" "")
                (if leftp left-margin-width right-margin-width)))
     "Use %k for further adjustment"
     1)
    (recenter line)))

(defun erc-fill-regarding-timestamp ()
  "Fills a text such that messages start at column `erc-fill-static-center'."
  (fill-region (point-min) (point-max) t t)
  (goto-char (point-min))
  (forward-line)
  (indent-rigidly (point) (point-max) (erc-timestamp-offset)))

(defun erc-timestamp-offset ()
  "Get length of timestamp if inserted left."
  (if (and (boundp 'erc-timestamp-format)
           erc-timestamp-format
           ;; FIXME use a more robust test than symbol equivalence.
           (eq erc-insert-timestamp-function 'erc-insert-timestamp-left)
           (not erc-hide-timestamps))
      (length (format-time-string erc-timestamp-format))
    0))

(provide 'erc-fill)

;;; erc-fill.el ends here
;; Local Variables:
;; generated-autoload-file: "erc-loaddefs.el"
;; End:
