
;;; pcsv.el --- Parser of csv -*- lexical-binding: t -*-

;; Author: Masahiro Hayashi <mhayashi1120@gmail.com>
;; Keywords: data
;; URL: http://github.com/mhayashi1120/Emacs-pcsv/raw/master/pcsv.el
;; Emacs: GNU Emacs 21 or later
;; Version: 1.3.1

;; This program is free software; you can redistribute it and/or
;; modify it under the terms of the GNU General Public License as
;; published by the Free Software Foundation; either version 3, or (at
;; your option) any later version.

;; This program is distributed in the hope that it will be useful, but
;; WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs; see the file COPYING.  If not, write to the
;; Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
;; Boston, MA 02110-1301, USA.

;;; Commentary:

;; pcsv provides parser of csv based on rfc4180
;; http://www.rfc-editor.org/rfc/rfc4180.txt

;;; Install:

;; Put this file into load-path'ed directory, and byte compile it if
;; desired. And put the following expression into your ~/.emacs.
;;
;;     (require 'pcsv)

;;; Usage:

;; Use `pcsv-parse-buffer', `pcsv-parse-file', `pcsv-parse-region' functions
;; to parse csv.

;; To handle huge csv file, use the lazy parser `pcsv-file-parser'.

;; To handle csv buffer like cursor, use the `pcsv-parser'.

;;; Code:

(defvar pcsv-separator ?,)

;;;###autoload
(defun pcsv-parse-buffer (&optional buffer)
  "Parse a current buffer as a csv.
BUFFER non-nil means parse buffer instead of current buffer."
  (with-current-buffer (or buffer (current-buffer))
    (pcsv-parse-region (point-min) (point-max))))

;;;###autoload
(defun pcsv-parse-file (file &optional coding-system)
  "Parse FILE as a csv file."
  (with-temp-buffer
    (let ((coding-system-for-read coding-system))
      (insert-file-contents file))
    (pcsv-parse-region (point-min) (point-max))))

;;;###autoload
(defun pcsv-parse-region (start end)
  "Parse region as a csv."
  (save-excursion
    (save-restriction
      (narrow-to-region start end)
      (pcsv-map 'identity))))

;;;###autoload
(defun pcsv-parser (&optional buffer)
  "Get a CSV parser to parse BUFFER.
This function supported only Emacs 24 or later.


Example:
\(setq parser (pcsv-parser))
\(let (tmp)
  (while (setq tmp (funcall parser))
    (print tmp)))
"
  (unless (>= emacs-major-version 24)
    (error "lexical binding is not supported"))
  (let ((buffer (or buffer (current-buffer)))
        (pos (point-min-marker)))
    (lambda ()
      (with-current-buffer buffer
        (save-excursion
          (goto-char pos)
          (prog1 (pcsv-read-line)
            (setq pos (point-marker))))))))

;;;###autoload
(defun pcsv-file-parser (file &optional coding-system block-size)
  "Create a csv parser to read huge FILE.
This csv parser accept a optional arg which non-nil means terminate the parser.

Optional arg BLOCK-SIZE indicate bytes to read FILE each time.

Example:
\(let ((parser (pcsv-file-parser \"/path/to/csv\")))
  (unwind-protect
      (let (tmp)
        (while (setq tmp (funcall parser))
          (print tmp)))
    ;; Must close the parser
    (funcall parser t)))
"
  (unless (>= emacs-major-version 24)
    (error "lexical binding is not supported"))
  (unless (file-exists-p file)
    (error "File is not exists %s" file))
  (when (and block-size
             (not (plusp block-size)))
    (error "Not a valid block size %s" block-size))
  (let* ((bufname (format " *pcsv parse %s* " file))
         (buffer (generate-new-buffer bufname))
         (block-reader
          (pcsv--file-reader buffer file coding-system block-size))
         eof reach-to-end)
    (lambda (&optional close)
      (cond
       (close
        (kill-buffer buffer))
       ((not (buffer-live-p buffer))
        nil)
       (reach-to-end
        (kill-buffer buffer)
        nil)
       (t
        ;; initialize
        (when (zerop (buffer-size buffer))
          (setq eof (funcall block-reader)))
        (with-current-buffer buffer
          (let (line)
            (while (catch 'fallback
                     (goto-char (point-min))
                     (setq line (condition-case nil
                                    (pcsv-read-line)
                                  (invalid-read-syntax nil)))
                     ;; After `pcsv-read-line' must point to bol.
                     ;; but last line may not have newline
                     (when (and (not eof)
                                (not (bolp)))
                       ;; retry read and fallback
                       (setq eof (funcall block-reader))
                       (throw 'fallback t))
                     ;; delete parsed csv line
                     (delete-region (point-min) (point))
                     nil))
            (when (and eof (zerop (buffer-size)))
              (kill-buffer buffer)
              (setq reach-to-end t))
            line)))))))

(defun pcsv--file-reader (buffer file coding block-size)
  (let ((pos 0)
        (size (or block-size
                  ;; suppress reading size
                  (/ large-file-warning-threshold 10)))
        (start (point-min-marker))
        eof codings cs)
    (set-buffer-multibyte t)
    (lambda ()
      (unless eof
        (with-current-buffer buffer
          (while
              (catch 'retry
                (goto-char (point-max))
                (let* ((res
                        (let ((coding-system-for-read 'binary))
                          (insert-file-contents
                           file nil pos (+ pos size))))
                       (attr (file-attributes file))
                       (size (nth 7 attr)))
                  ;; res has inserted bytes (not chars)
                  (setq pos (+ pos (cadr res)))
                  (setq eof (>= pos size))
                  (save-excursion
                    (goto-char (point-max))
                    (unless eof
                      (forward-line 0)
                      (when (bobp)
                        (throw 'retry t)))
                    (setq cs (or coding
                                 ;;TODO reconsider
                                 (with-coding-priority codings
                                   (detect-coding-region start (point) t))))
                    (unless (memq cs codings)
                      (setq codings (cons cs codings)))
                    ;; proceeded line may have broken char.
                    ;; so decode coding just all char in a line was proceeded.
                    (decode-coding-region start (point) cs)
                    (setq start (point-marker))))
                nil))))
      eof)))

(defun pcsv-map (function)
  (save-excursion
    (let (lis)
      (goto-char (point-min))
      (while (not (eobp))
        (setq lis (cons
                   (funcall function (pcsv-read-line))
                   lis)))
      (nreverse lis))))

(defvar pcsv--eobp)
(defvar pcsv--quoting-read)

(defun pcsv-peek ()
  (char-after))

(defun pcsv-read-line ()
  (let (pcsv--eobp v lis)
    (while (and (or (null v) (not (bolp)))
                (setq v (pcsv-read)))
      (setq lis (cons v lis)))
    (nreverse lis)))

(defun pcsv-read-char ()
  (cond
   ((eobp)
    (when pcsv--quoting-read
      ;; must be ended before call this function.
      (signal 'invalid-read-syntax
              (list "Unexpected end of buffer")))
    nil)
   (t
    (forward-char)
    (let* ((c (char-before)))
      (cond
       ((null c))
       ((and pcsv--quoting-read (eq c ?\"))
        (let ((c2 (pcsv-peek)))
          (cond
           ((eq ?\" c2)
            (forward-char)
            (setq c ?\"))
           ((memq c2 `(,pcsv-separator ?\n))
            (forward-char)
            (setq c nil))
           ((null c2)
            ;; end of buffer
            (setq c nil))
           (t
            (signal 'invalid-read-syntax
                    (list (format "Expected `\"' but got `%c'" c2)))))))
       ((null pcsv--quoting-read)
        (cond
         ((eq c pcsv-separator)
          (setq c nil))
         ((eq c ?\n)
          (setq c nil)))))
      c))))

(defun pcsv-read ()
  (let ((c (pcsv-peek))
        lis)
    (cond
     ((null c)
      ;; handling last line has no newline
      (cond
       (pcsv--eobp nil)
       ((eq (char-before) pcsv-separator)
        (setq pcsv--eobp t)
        "")
       (t nil)))
     (t
      (let ((pcsv--quoting-read
             (when (eq c ?\")
               (forward-char)
               t)))
        (while (setq c (pcsv-read-char))
          (setq lis (cons c lis))))
      (concat (nreverse lis))))))

(provide 'pcsv)

;;; pcsv.el ends here
