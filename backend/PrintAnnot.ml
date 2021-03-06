(* *********************************************************************)
(*                                                                     *)
(*              The Compcert verified compiler                         *)
(*                                                                     *)
(*          Xavier Leroy, INRIA Paris-Rocquencourt                     *)
(*                                                                     *)
(*  Copyright Institut National de Recherche en Informatique et en     *)
(*  Automatique.  All rights reserved.  This file is distributed       *)
(*  under the terms of the INRIA Non-Commercial License Agreement.     *)
(*                                                                     *)
(* *********************************************************************)

(* Printing annotations in asm syntax *)

open Printf
open Datatypes
open Integers
open Floats
open Camlcoq
open AST
open Memdata
open Asm

(** All files used in the debug entries *)
module StringSet = Set.Make(String)
let all_files : StringSet.t ref = ref StringSet.empty
let add_file file =
  all_files := StringSet.add file !all_files


(** Line number annotations *)

let filename_info : (string, int * Printlines.filebuf option) Hashtbl.t
                  = Hashtbl.create 7

let last_file = ref ""

let reset_filenames () =
  Hashtbl.clear filename_info; last_file := ""

let close_filenames () =
  Hashtbl.iter
    (fun file (num, fb) ->
       match fb with Some b -> Printlines.close b | None -> ())
    filename_info;
  reset_filenames()

let enter_filename f =
  let num = Hashtbl.length filename_info + 1 in
  let filebuf =
    if !Clflags.option_S || !Clflags.option_dasm then begin
      try Some (Printlines.openfile f)
      with Sys_error _ -> None
    end else None in
  Hashtbl.add filename_info f (num, filebuf);
  (num, filebuf)

(* Add file and line debug location, using GNU assembler-style DWARF2
   directives *)

let print_file_line oc pref file line =
  if !Clflags.option_g && file <> "" then begin
    let (filenum, filebuf) =
      try
        Hashtbl.find filename_info file
      with Not_found ->
        let (filenum, filebuf as res) = enter_filename file in
        fprintf oc "	.file	%d %S\n" filenum file;
        res in
    fprintf oc "	.loc	%d %d\n" filenum line;
    match filebuf with
    | None -> ()
    | Some fb -> Printlines.copy oc pref fb line line
  end

(* Add file and line debug location, using DWARF2 directives in the style
   of Diab C 5 *)

let print_file_line_d2 oc pref file line =
  if !Clflags.option_g && file <> "" then begin
    let (_, filebuf) =
      try
        Hashtbl.find filename_info file
      with Not_found ->
        enter_filename file in
    if file <> !last_file then begin
      fprintf oc "	.d2file	%S\n" file;
      last_file := file
    end;
    fprintf oc "	.d2line	%d\n" line;
    match filebuf with
    | None -> ()
    | Some fb -> Printlines.copy oc pref fb line line
  end

(** "True" annotations *)

let re_annot_param = Str.regexp "%%\\|%[1-9][0-9]*"

let rec print_annot print_preg sp_reg_name oc = function
  | AA_base x -> print_preg oc x
  | AA_int n -> fprintf oc "%ld" (camlint_of_coqint n)
  | AA_long n -> fprintf oc "%Ld" (camlint64_of_coqint n)
  | AA_float n -> fprintf oc "%.18g" (camlfloat_of_coqfloat n)
  | AA_single n -> fprintf oc "%.18g" (camlfloat_of_coqfloat32 n)
  | AA_loadstack(chunk, ofs) ->
      fprintf oc "mem(%s + %ld, %ld)"
         sp_reg_name
         (camlint_of_coqint ofs)
         (camlint_of_coqint (size_chunk chunk))
  | AA_addrstack ofs ->
      fprintf oc "(%s + %ld)"
         sp_reg_name
         (camlint_of_coqint ofs)
  | AA_loadglobal(chunk, id, ofs) ->
      fprintf oc "mem(\"%s\" + %ld, %ld)"
         (extern_atom id)
         (camlint_of_coqint ofs)
         (camlint_of_coqint (size_chunk chunk))
  | AA_addrglobal(id, ofs) ->
      fprintf oc "(\"%s\" + %ld)"
         (extern_atom id)
         (camlint_of_coqint ofs)
  | AA_longofwords(hi, lo) ->
      fprintf oc "(%a * 0x100000000 + %a)"
        (print_annot print_preg sp_reg_name) hi
        (print_annot print_preg sp_reg_name) lo

let print_annot_text print_preg sp_reg_name oc txt args =
  let print_fragment = function
  | Str.Text s ->
      output_string oc s
  | Str.Delim "%%" ->
      output_char oc '%'
  | Str.Delim s ->
      let n = int_of_string (String.sub s 1 (String.length s - 1)) in
      try
        print_annot print_preg sp_reg_name oc (List.nth args (n-1))
      with Failure _ ->
        fprintf oc "<bad parameter %s>" s in
  List.iter print_fragment (Str.full_split re_annot_param txt);
  fprintf oc "\n"

let print_annot_stmt print_preg sp_reg_name oc txt tys args =
  print_annot_text print_preg sp_reg_name oc txt args

let print_annot_val print_preg oc txt args =
  print_annot_text print_preg "<internal error>" oc txt
    (List.map (fun r -> AA_base r) args)

(** Inline assembly *)

let re_asm_param = Str.regexp "%%\\|%[0-9]+"

let print_inline_asm print_preg oc txt sg args res =
  let operands =
    if sg.sig_res = None then args else res @ args in
  let print_fragment = function
  | Str.Text s ->
      output_string oc s
  | Str.Delim "%%" ->
      output_char oc '%'
  | Str.Delim s ->
      let n = int_of_string (String.sub s 1 (String.length s - 1)) in
      try
        print_preg oc (List.nth operands n)
      with Failure _ ->
        fprintf oc "<bad parameter %s>" s in
  List.iter print_fragment (Str.full_split re_asm_param txt);
  fprintf oc "\n"


(** Print CompCert version and command-line as asm comment *)

let print_version_and_options oc comment =
  fprintf oc "%s File generated by CompCert %s\n" comment Configuration.version;
  fprintf oc "%s Command line:" comment;
  for i = 1 to Array.length Sys.argv - 1 do
    fprintf oc " %s" Sys.argv.(i)
  done;
  fprintf oc "\n"

