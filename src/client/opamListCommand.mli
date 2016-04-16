(**************************************************************************)
(*                                                                        *)
(*    Copyright 2012-2015 OCamlPro                                        *)
(*    Copyright 2012 INRIA                                                *)
(*                                                                        *)
(*  All rights reserved.This file is distributed under the terms of the   *)
(*  GNU Lesser General Public License version 3.0 with linking            *)
(*  exception.                                                            *)
(*                                                                        *)
(*  OPAM is distributed in the hope that it will be useful, but WITHOUT   *)
(*  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY    *)
(*  or FITNESS FOR A PARTICULAR PURPOSE.See the GNU General Public        *)
(*  License for more details.                                             *)
(*                                                                        *)
(**************************************************************************)

(** Functions handling the "opam list" subcommand *)

open OpamTypes
open OpamStateTypes

(** Switches to determine what to include when querying (reverse)
    dependencies *)
type dependency_toggles = {
  recursive: bool;
  depopts: bool;
  build: bool;
  test: bool;
  doc: bool;
  dev: bool;
}

val default_dependency_toggles: dependency_toggles

type pattern_selector = {
  case_sensitive: bool;
  exact: bool;
  glob: bool;
  fields: string list;
  ext_fields: bool; (** Match on raw strings in [x-foo] fields *)
}

val default_pattern_selector: pattern_selector

(** Package selectors used to filter the set of packages *)
type selector =
  | Installed
  | Root
  | Available
  | Installable
  | Depends_on of dependency_toggles * atom list
  | Required_by of dependency_toggles * atom list
  | Solution of dependency_toggles * atom list
  | Pattern of pattern_selector * string
  | Flag of package_flag

(** Applies a formula of selectors to filter the package from a given switch
    state *)
val filter: 'a switch_state -> selector OpamFormula.formula -> package_set

(** Element of package information to be printed *)
type output_format =
  | Name               (** Name without version *)
  | Package            (** [name.version] *)
  | Synopsis           (** One-line package description *)
  | Synopsis_or_target (** pinning target if pinned, synopsis otherwise *)
  | Field of string    (** The value of the given opam-file field *)
  | Installed_version  (** Installed version or "--" if none *)
  | Pinning_target     (** Empty string if not pinned *)
  | Raw                (** The full contents of the opam file (reformatted) *)
  | Full_summary       (** Multi-line report on the package status (available
                           versions, switches where installed...) *)
val default_list_format: output_format list

(** Outputs a list of packages as a table according to the formatting options *)
val display:
  'a switch_state ->
  format:output_format list ->
  dependency_order:bool ->
  all_versions:bool ->
  package_set -> unit

(** Display all available packages that match any of the regexps. *)
val list:
  'a global_state ->
  print_short:bool ->
  filter:[`all|`installed|`roots|`installable] ->
  order:[`normal|`depends] ->
  exact_name:bool ->
  case_sensitive:bool ->
  ?depends:(atom list) ->
  ?reverse_depends:bool -> ?recursive_depends:bool -> ?resolve_depends:bool ->
  ?depopts:bool -> ?depexts:string list -> ?dev:bool ->
  string list ->
  unit

(** Display a general summary of a collection of packages. *)
val info:
  'a global_state ->
  fields:string list -> raw_opam:bool -> where:bool -> atom list -> unit
