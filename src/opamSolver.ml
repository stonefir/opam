(***********************************************************************)
(*                                                                     *)
(*    Copyright 2012 OCamlPro                                          *)
(*    Copyright 2012 INRIA                                             *)
(*                                                                     *)
(*  All rights reserved.  This file is distributed under the terms of  *)
(*  the GNU Public License version 3.0.                                *)
(*                                                                     *)
(*  OPAM is distributed in the hope that it will be useful,            *)
(*  but WITHOUT ANY WARRANTY; without even the implied warranty of     *)
(*  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the      *)
(*  GNU General Public License for more details.                       *)
(*                                                                     *)
(***********************************************************************)

open OpamTypes

let log fmt = OpamGlobals.log "SOLVER" fmt

let map_reinstall ~installed a =
  match a with
  | To_change (None, nv) ->
      if OpamPackage.Set.mem nv installed then
        To_recompile nv
      else
        let name = OpamPackage.name nv in
        if OpamPackage.Set.exists (fun nv -> OpamPackage.name nv = name) installed then
          let old_nv = OpamPackage.Set.find (fun nv -> OpamPackage.name nv = name) installed in
          To_change (Some old_nv, nv)
        else
          a
  | _ -> a

let string_of_action = function
  | To_change (None, p)   -> Printf.sprintf " - install %s" (OpamPackage.to_string p)
  | To_change (Some o, p) ->
      let f action =
        Printf.sprintf " - %s %s to %s" action
          (OpamPackage.to_string o) (OpamPackage.Version.to_string (OpamPackage.version p)) in
      if OpamPackage.Version.compare (OpamPackage.version o) (OpamPackage.version p) < 0 then
        f "upgrade"
      else
        f "downgrade"
  | To_recompile p        -> Printf.sprintf " - recompile %s" (OpamPackage.to_string p)
  | To_delete p           -> Printf.sprintf " - delete %s" (OpamPackage.to_string p)

type package_action = {
  cudf: Cudf.package;
  mutable action: action;
}

let action t = t.action

module PA_graph = struct

  module PkgV =  struct

    type t = package_action

    let compare t1 t2 =
      Algo.Defaultgraphs.PkgV.compare t1.cudf t2.cudf

    let hash t =
      Algo.Defaultgraphs.PkgV.hash t.cudf

    let equal t1 t2 =
      Algo.Defaultgraphs.PkgV.equal t1.cudf t2.cudf

  end

  module PG = Graph.Imperative.Digraph.ConcreteBidirectional (PkgV)
  module Topological = Graph.Topological.Make (PG)
  module Parallel = OpamParallel.Make(struct
    include PG
    include Topological
    let string_of_vertex v = string_of_action v.action
  end)
  include PG

  let iter_update_reinstall ~installed g =
    PG.iter_vertex (fun v ->
      v.action <- map_reinstall ~installed v.action
    ) g

end

let string_of_request r =
  Printf.sprintf "install:%s remove:%s upgrade:%s"
    (OpamFormula.string_of_conjunction r.wish_install)
    (OpamFormula.string_of_conjunction r.wish_remove)
    (OpamFormula.string_of_conjunction r.wish_upgrade)

type solution = PA_graph.t OpamTypes.solution

let stats sol =
  let s_install, s_reinstall, s_upgrade, s_downgrade =
    PA_graph.fold_vertex
      (fun pkg (to_install, to_reinstall, to_upgrade, to_downgrade) ->
        match action pkg with
        | To_change (None, _)             -> succ to_install, to_reinstall, to_upgrade, to_downgrade
        | To_change (Some x, y) when x<>y ->
          if OpamPackage.Version.compare (OpamPackage.version x) (OpamPackage.version y) < 0 then
            to_install, to_reinstall, succ to_upgrade, to_downgrade
          else
            to_install, to_reinstall, to_upgrade, succ to_downgrade
        | To_change (Some _, _)
        | To_recompile _                  -> to_install, succ to_reinstall, to_upgrade, to_downgrade
        | To_delete _ -> assert false)
      sol.to_add
      (0, 0, 0, 0) in
  let s_remove = List.length sol.to_remove in
  { s_install; s_reinstall; s_upgrade; s_downgrade; s_remove }

let string_of_stats stats =
  Printf.sprintf "%d to install | %d to reinstall | %d to upgrade | %d to downgrade | %d to remove"
    stats.s_install
    stats.s_reinstall
    stats.s_upgrade
    stats.s_downgrade
    stats.s_remove

let solution_is_empty s =
  s.to_remove = [] && PA_graph.is_empty s.to_add

let print_solution t =
  if t.to_remove = [] && PA_graph.is_empty t.to_add then
    ()
  (*Globals.msg
    "No actions will be performed, the current state satisfies the request.\n"*)
  else
    let f = OpamPackage.to_string in
    List.iter (fun p -> OpamGlobals.msg " - remove %s\n" (f p)) t.to_remove;
    PA_graph.Topological.iter
      (function { action ; _ } -> OpamGlobals.msg "%s\n" (string_of_action action))
      t.to_add

type 'a internal_action =
  | I_to_change of 'a option * 'a
  | I_to_delete of 'a
  | I_to_recompile of 'a

let string_of_internal_action f = function
  | I_to_change (None, p)   -> Printf.sprintf "Install: %s" (f p)
  | I_to_change (Some o, p) ->
      Printf.sprintf "Update: %s (Remove) -> %s (Install)" (f o) (f p)
  | I_to_recompile p        -> Printf.sprintf "Recompile: %s" (f p)
  | I_to_delete p           -> Printf.sprintf "Delete: %s" (f p)

let action_map f = function
  | I_to_change (Some x, y) -> To_change (Some (f x), f y)
  | I_to_change (None, y)   -> To_change (None, f y)
  | I_to_delete y           -> To_delete (f y)
  | I_to_recompile y        -> To_recompile (f y)

type 'a internal_request = {
  i_wish_install:  'a list;
  i_wish_remove :  'a list;
  i_wish_upgrade:  'a list;
}

let string_of_internal_request f r =
  Printf.sprintf "install:%s remove:%s upgrade:%s"
    (OpamMisc.string_of_list f r.i_wish_install)
    (OpamMisc.string_of_list f r.i_wish_remove)
    (OpamMisc.string_of_list f r.i_wish_upgrade)

let request_map f r =
  let f = List.map f in
  { i_wish_install = f r.wish_install
  ; i_wish_remove  = f r.wish_remove
  ; i_wish_upgrade = f r.wish_upgrade }

type package = Debian.Packages.package

let string_of_package p =
  let installed =
    if List.mem_assoc "status" p.Debian.Packages.extras
      && List.assoc "status" p.Debian.Packages.extras = "  installed"
    then "installed"
    else "not-installed" in
  Printf.sprintf "%s::%s(%s)"
    p.Debian.Packages.name p.Debian.Packages.version installed

let string_of_packages l =
  OpamMisc.string_of_list string_of_package l

let string_of_cudf (p, c) =
  let const = function
    | None       -> ""
    | Some (r,v) -> Printf.sprintf " (%s %d)" (OpamCompiler.Version.string_of_relop r) v in
  Printf.sprintf "%s%s" p (const c)

let string_of_internal_request =
  string_of_internal_request string_of_cudf

let string_of_cudfs l =
  OpamMisc.string_of_list string_of_cudf l

(* Universe of packages *)
type universe = U of package list

(* Subset of packages *)
type packages = P of package list

let string_of_cudf_package p =
  let installed = if p.Cudf.installed then "installed" else "not-installed" in
  Printf.sprintf "%s.%d(%s)"
    p.Cudf.package
    p.Cudf.version installed

let string_of_cudf_packages l =
  OpamMisc.string_of_list string_of_cudf_package l

let string_of_answer l =
  OpamMisc.string_of_list (string_of_internal_action string_of_cudf_package)  l

let string_of_universe u =
  string_of_cudf_packages (Cudf.get_packages u)

let string_of_reason table r =
  let open Algo.Diagnostic in
  match r with
  | Conflict (i,j,_) ->
    let nvi = OpamPackage.of_cudf table i in
    let nvj = OpamPackage.of_cudf table j in
    Printf.sprintf "Conflict between %s and %s."
      (OpamPackage.to_string nvi) (OpamPackage.to_string nvj)
  | Missing (i,_) ->
    let nv = OpamPackage.of_cudf table i in
    Printf.sprintf "Missing %s." (OpamPackage.to_string nv)
  | Dependency _ -> ""

let make_chains root depends =
  let open Algo.Diagnostic in
  let d = Hashtbl.create 16 in
  let init = function
    | Dependency (i,_,j) -> List.iter (Hashtbl.add d i) j
    | _ -> () in
  List.iter init depends;
  let rec unroll root =
    match Hashtbl.find_all d root with
    | []       -> [[root]]
    | children ->
      let chains = List.flatten (List.map unroll children) in
      if root.Cudf.package = "dummy" || root.Cudf.package = "dose-dummy-request" then
        chains
      else
        List.map (fun cs -> root :: cs) chains in
  List.filter (function [x] -> false | _ -> true) (unroll root)

exception Found of Cudf.package

let string_of_reasons table reasons =
  let open Algo.Diagnostic in
  let depends, reasons = List.partition (function Dependency _ -> true | _ -> false) reasons in
  let root =
    try List.iter (function Dependency (p,_,_) -> raise (Found p) | _ -> ()) depends; assert false
    with Found p -> p in
  let chains = make_chains root depends in
  let rec string_of_chain = function
    | []   -> ""
    | [p]  -> OpamPackage.to_string (OpamPackage.of_cudf table p)
    | p::t -> Printf.sprintf "%s <- %s" (OpamPackage.to_string (OpamPackage.of_cudf table p)) (string_of_chain t) in
  let b = Buffer.create 1024 in
  let string_of_chain c = string_of_chain (List.rev c) in
  List.iter (fun r ->
    Printf.bprintf b " - %s\n" (string_of_reason table r)
  ) reasons;
  List.iter (fun c ->
    Printf.bprintf b " + %s\n" (string_of_chain c)
  ) chains;
  Buffer.contents b

let depopts pkg =
  let opt = OpamFile.OPAM.s_depopts in
  if List.mem_assoc opt pkg.Cudf.pkg_extra then
    match List.assoc opt pkg.Cudf.pkg_extra with
    | `String s ->
      let value = OpamParser.value OpamLexer.token (Lexing.from_string s) in
      Some (OpamFormat.parse_formula value)
    | _ -> assert false
  else
    None

let encode ((n,a),c) = (Common.CudfAdd.encode n,a),c
let lencode = List.map encode
let llencode = List.map lencode

(* Extra CUDF properties *)
let extra_properties = [
  (OpamFile.OPAM.s_depopts, `String None)
]

module O_pkg = struct
  type t = Cudf.package
  let to_string = string_of_cudf_package
  let summary pkg = pkg.Cudf.package, pkg.Cudf.version
  let compare pkg1 pkg2 =
    compare (summary pkg1) (summary pkg2)
end

module PkgMap = OpamMisc.Map.Make (O_pkg)

module PkgSet = OpamMisc.Set.Make (O_pkg)

module Graph = struct
  open Algo

  module PG = struct
    module G = Defaultgraphs.PackageGraph.G
    let union g1 g2 =
      let g1 = G.copy g1 in
      let () =
        begin
          G.iter_vertex (G.add_vertex g1) g2;
          G.iter_edges (G.add_edge g1) g2;
        end in
      g1
    include G
  end

  module PO = Defaultgraphs.GraphOper (PG)

  module type FS = sig
    type iterator
    val start : PG.t -> iterator
    val step : iterator -> iterator
    val get : iterator -> PG.V.t
  end

  module Make_fs (F : FS) = struct
    let fold f acc g =
      let rec aux acc iter =
        match try Some (F.get iter, F.step iter) with Exit -> None with
        | None -> acc
        | Some (x, iter) -> aux (f acc x) iter in
      aux acc (F.start g)
  end

  module PG_topo = Graph.Topological.Make (PG)

  let dep_reduction v =
    let g = Defaultgraphs.PackageGraph.dependency_graph (Cudf.load_universe v) in
    PO.transitive_reduction g;
    g

  let output_graph g filename =
    if !OpamGlobals.debug then (
      let fd = open_out (filename ^ ".dot") in
      Defaultgraphs.PackageGraph.DotPrinter.output_graph fd g;
      close_out fd
    )

  let tocudf table pkg =
    let open Debian.Debcudf in
    let options = {
      default_options with extras_opt = List.map (fun (s,t) -> (s, (s,t))) extra_properties
    } in
    Debian.Debcudf.tocudf ~options table pkg

  let cudfpkg_of_debpkg table = List.map (tocudf table)

  let get_table l_pkg_pb f =
    let table = Debian.Debcudf.init_tables l_pkg_pb in
    let v = f table (cudfpkg_of_debpkg table l_pkg_pb) in
    (* Debian.Debcudf.clear table in *)
    v

  let topo_fold g pkg_set =
    let _, l =
      PG_topo.fold
        (fun p (set, l) ->
          let add_succ_rem pkg set act =
            (let set = PkgSet.remove pkg set in
             try
               List.fold_left (fun set x ->
                 PkgSet.add x set) set (PG.succ g pkg)
             with _ -> set),
            act :: l in

          if PkgSet.mem p set then
            add_succ_rem p set p
          else
            set, l)
        g
        (pkg_set, []) in
    l

  (* Add the optional dependencies to the list of dependencies *)
  (* The dependencies are encoded in the pkg_extra of cudf packages,
     as a raw string. So we need to parse the string and convert it
     to cudf list of package dependencies.
     NOTE: the cudf encoding (to replace '_' by '%5f' is done in
     file.ml when we create the debian package. It could make sense
     to do it here. *)
  let extended_dependencies table pkg =
    match depopts pkg with
    | Some deps ->
      let cnf = OpamFormula.to_cnf deps in
      let deps = Debian.Debcudf.lltocudf table (llencode cnf) in
      { pkg with Cudf.depends = deps @ pkg.Cudf.depends }
    | None -> pkg

  let filter_dependencies f_direction ?(depopts=false) (U l_pkg_pb) (P pkg_l) =
    let pkg_map =
      List.fold_left
        (fun map pkg -> OpamPackage.Map.add (OpamPackage.of_dpkg pkg) pkg map)
        OpamPackage.Map.empty
        l_pkg_pb in
    get_table l_pkg_pb
      (fun table pkglist ->
        let pkglist =
          if depopts then
            List.map (extended_dependencies table) pkglist
          else
            pkglist in
        let pkg_set = List.fold_left
          (fun accu pkg -> PkgSet.add (tocudf table pkg) accu)
          PkgSet.empty
          pkg_l in
        let g = f_direction (dep_reduction pkglist) in
        output_graph g "filter-depends";
        let pkg_topo = topo_fold g pkg_set in
        List.map
          (fun pkg -> OpamPackage.Map.find (OpamPackage.of_cudf table pkg) pkg_map)
          pkg_topo)

  let filter_backward_dependencies = filter_dependencies (fun x -> x)
  let filter_forward_dependencies = filter_dependencies PO.O.mirror

end

module CudfDiff : sig

  type answer = Cudf.package internal_action list

  val resolve:
    Cudf.universe ->
    Cudf_types.vpkg internal_request ->
    (Cudf.package internal_action list, Algo.Diagnostic.reason list) result

end = struct

  type answer = Cudf.package internal_action list

  module Cudf_set = struct

    include Common.CudfAdd.Cudf_set

    let to_string s =
      OpamMisc.string_of_list string_of_cudf_package (elements s)

    let choose_one s =
      match elements s with
      | []  -> raise Not_found
      | [x] -> x
      | _   -> invalid_arg "choose_one"

  end

  let to_cudf univ req = (
    Common.CudfAdd.add_properties Cudf.default_preamble extra_properties,
    univ,
    { Cudf.request_id = "opam";
           install    = req.i_wish_install;
           remove     = req.i_wish_remove;
           upgrade    = req.i_wish_upgrade;
           req_extra  = [] }
  )

  (* Return the universe in which the system has to go *)
  let get_final_universe univ req =
    let open Algo.Depsolver in
    log "RESOLVE(final-state): universe=%s" (string_of_universe univ);
    log "RESOLVE(final-state): request=%s" (string_of_internal_request req);
    match Algo.Depsolver.check_request ~explain:true (to_cudf univ req) with
    | Sat (_,u) -> Success u
    | Error str -> OpamGlobals.error_and_exit "solver error: str"
    | Unsat r   ->
      let open Algo.Diagnostic in
      match r with
      | Some {result=Failure f} -> Conflicts f
      | _                       -> failwith "opamSolver"


  (* Transform a diff from current to final state into a list of actions *)
  let actions_of_diff diff =
    Hashtbl.fold (fun pkgname s acc ->
      let add x = x :: acc in
      let removed =
        try Some (Cudf_set.choose_one s.Common.CudfDiff.removed)
        with Not_found -> None in
      let installed =
        try Some (Cudf_set.choose_one s.Common.CudfDiff.installed)
        with Not_found -> None in
      match removed, installed with
      | None      , Some p     -> add (I_to_change (None, p))
      | Some p    , None       -> add (I_to_delete p)
      | Some p_old, Some p_new -> add (I_to_change (Some p_old, p_new))
      | None      , None       -> acc
    ) diff []

  (* Do not try to optimize installations *)
  let resolve_simple univ req =
    let open Algo in
    match get_final_universe univ req with
    | Conflicts e -> Conflicts e
    | Success final_universe ->
      log "RESOLVE(simple): final-universe=%s" (string_of_universe final_universe);
        try
          let diff = Common.CudfDiff.diff univ final_universe in
          Success (actions_of_diff diff)
        with Cudf.Constraint_violation s ->
          OpamGlobals.error_and_exit "constraint violations: %s" s

  (* Partition the packages in an answer into two sets: the ones with
     a version constraint in the initial request, and the one
     without. *)
  let packages_of_answer univ req ans =
    let keep_versions, change_versions =
      List.fold_left (function (keep, change) -> function
      | I_to_delete _      -> (keep   , change)
      | I_to_recompile p   -> (p::keep, change)
      | I_to_change (_, p) ->
        try
          let r = List.find (fun (name, _) -> p.Cudf.package = name) req.i_wish_install in
          begin match r with
          | _, None -> (keep   , p::change)
          | _, _    -> (p::keep, change)
          end
        with Not_found ->
          (keep, p::change)
      ) ([],[]) ans in
    keep_versions, change_versions

  (* Resolution with heuristic to install the minimun set of packages *)
  let resolve univ req =
    if req.i_wish_install = [] then
      resolve_simple univ req
    else match resolve_simple univ req with
    | Conflicts c -> Conflicts c
    | Success ans ->

      let keep_versions, change_versions = packages_of_answer univ req ans in
      match change_versions with
      | [] -> Success ans
      | _  ->
        log "RESOLVE(optimization/0) ans=%s" (string_of_answer ans);
        log "RESOLVE(optimization/1) keep=%s, change=%s\n"
          (string_of_cudf_packages keep_versions)
          (string_of_cudf_packages change_versions);

        let versions_map =
          List.fold_left (fun map p ->
            let p_map =
              try  OpamMisc.StringMap.find p.Cudf.package map
              with Not_found -> OpamMisc.IntMap.empty in
            let p_map = OpamMisc.IntMap.add p.Cudf.version p p_map in
            OpamMisc.StringMap.add p.Cudf.package p_map map
          ) OpamMisc.StringMap.empty (Cudf.get_packages univ) in

        let find_max n =
          let _, p = OpamMisc.IntMap.max_binding (OpamMisc.StringMap.find n versions_map) in
          p.Cudf.version in

        (* we compute the max version for every packages with no version constraints *)
        let mk_eq p  = p.Cudf.package, Some (`Eq , p.Cudf.version) in
        let mk_ge p  = p.Cudf.package, Some (`Geq, p.Cudf.version) in
        let mk_max p = p.Cudf.package, Some (`Eq , find_max p.Cudf.package) in

        (* Return the constraint where max_pkgs are set to max *)
        let i_wish_upgrade max_pkgs =
          let max = List.map mk_max max_pkgs in
          let ge = List.map mk_ge (List.filter (fun p -> not (List.mem p max_pkgs)) change_versions) in
          List.map mk_eq keep_versions @ max @ ge in

        (* Minimize the installed packages from the request *)
        let installed = Cudf.get_packages ~filter:(fun p -> p.Cudf.installed) univ in
        let installed =
          List.filter (fun p -> not (List.exists (fun (n,_) -> n=p.Cudf.package) req.i_wish_remove)) installed in

        let is_installed name =
          List.exists (fun p -> p.Cudf.package = name) installed in
        let minimize request =
          let pkgs =
            List.map (fun (n,_) ->
              match Cudf.get_packages ~filter:(fun p -> p.Cudf.package=n) univ with
              | [] -> assert false
              | h::_ -> h
            ) request in
          let depends = Algo.Defaultgraphs.PackageGraph.dependency_graph_list univ pkgs in
          let exists (name,_) =
            is_installed name ||
            Graph.PG.fold_vertex (fun v accu -> accu || v.Cudf.package=name) depends false in
          List.filter exists request in

        let process max_pkgs =
          let to_upgrade = minimize (i_wish_upgrade max_pkgs) in
          let to_keep = List.filter (fun p -> List.for_all (fun (n,_) -> n <> p.Cudf.package) to_upgrade) installed in
          let to_keep = List.map mk_eq to_keep in
          let i_wish_upgrade = to_upgrade @ to_keep in
          log "INTERNAL(optimization/2) i_wish_upgrade=%s" (string_of_cudfs i_wish_upgrade);
          resolve_simple univ { i_wish_install = [] ; i_wish_remove = [] ; i_wish_upgrade } in

        (* 1. try to upgrade each package independently *)
        let max_pkgs = ref [] in
        List.iter (fun pkg ->
          match process [pkg] with
          | Conflicts _ -> ()
          | Success _   -> max_pkgs := pkg :: !max_pkgs
        ) change_versions;
        log "INTERNAL(optimization/3) max_pkgs=%s" (string_of_cudf_packages !max_pkgs);
        match process !max_pkgs with
        | Conflicts _ -> Success ans
        | Success ans -> Success ans

end

let output_universe name universe =
  if !OpamGlobals.debug then (
    let oc = open_out (name ^ ".cudf") in
    Cudf_printer.pp_universe oc universe;
    close_out oc;
    let g = Graph.dep_reduction (Cudf.get_packages universe) in
    Graph.output_graph g name;
  )

let resolve (U l_pkg_pb) req installed =
  (* filter-out the default package from the universe *)
  let l_pkg_pb =
    List.filter
      (fun pkg -> pkg.Debian.Packages.name <> OpamGlobals.default_package)
      l_pkg_pb in
  let filter ((n,_),_) = n <> OpamGlobals.default_package in
  let req = {
    wish_install = List.filter filter req.wish_install;
    wish_remove  = List.filter filter req.wish_remove;
    wish_upgrade = List.filter filter req.wish_upgrade;
  } in
  log "RESOLVE universe=%s" (string_of_packages (List.rev l_pkg_pb));
  log "RESOLVE request=%s" (string_of_request req);
  Graph.get_table l_pkg_pb
    (fun table pkglist ->
      let package_map pkg = OpamPackage.of_cudf table pkg in

      let i_req =
        request_map
          (fun x ->
            match Debian.Debcudf.ltocudf table [x] with
            | [n,c] -> Common.CudfAdd.encode n, c
            | _   -> failwith "TODO"
          ) req in
      let resolve universe =
        CudfDiff.resolve universe i_req in

      let req_only_remove =
        (** determine if the request is a remove case *)
        match req with
        | { wish_remove = _ :: _; _ } -> true
        | _ -> false in

      (** [graph_simple] contains the graph of packages
          where the dependency relation is without optional dependencies  *)
      let graph_simple, universe, sol_o =
        let universe0 = Cudf.load_universe pkglist in
        let universe = Cudf.load_universe (List.map (Graph.extended_dependencies table) pkglist) in
        let universe1 =
          if req_only_remove then
            (* Universe with all the optional dependencies *)
            universe
          else (* Universe without optional dependencies *)
            universe0 in
        output_universe "universe-all" universe;
        output_universe "universe" universe0;
        Graph.dep_reduction (Cudf.get_packages ~filter:(fun p -> p.Cudf.installed) universe0),
        universe,
        resolve universe1 in

      log "full-universe: (*%B*) %s" req_only_remove (string_of_universe universe);
      let create_graph name filter =
        let g = Graph.dep_reduction (Cudf.get_packages ~filter universe) in
        Graph.output_graph g name;
        g in

      let action_of_answer l =
        log "SOLUTION: %s" (string_of_answer l);

        (** compute all packages to remove *)
        let l_del_p, set_del =
          OpamMisc.filter_map (function
          | I_to_change (Some pkg, _)
          | I_to_delete pkg -> Some pkg
          | _ -> None) l,
          PkgSet.of_list
            (OpamMisc.filter_map (function
            | I_to_delete pkg -> Some pkg
            | _ -> None) l) in

        (** compute initial packages to add *)
        let map_add =
          PkgMap.of_list (OpamMisc.filter_map (function
          | I_to_change (None, _) when req_only_remove -> None
          | I_to_change (_, pkg) as act -> Some (pkg, act)
          | I_to_delete _ -> None
          | I_to_recompile _ -> assert false) l) in

        (** [graph_toinstall] is similar to [graph_simple] except that
            the dependency relation is complete *)
        let graph_toinstall =
          Graph.PO.O.mirror
            (create_graph "to-install" (fun p -> p.Cudf.installed || PkgMap.mem p map_add)) in
        let graph_toinstall =
          let graph_toinstall = Graph.PG.copy graph_toinstall in
          List.iter (Graph.PG.remove_vertex graph_toinstall) l_del_p;
          graph_toinstall in

        (** compute packages to recompile (and perform the merge with packages to add) *)
        let _, map_act =
          Graph.PG_topo.fold
            (fun pkg (set_recompile, l_act) ->
              let add_succ_rem pkg set act =
                (let set = PkgSet.remove pkg set in
                 try
                   List.fold_left
                     (fun set x -> PkgSet.add x set)
                     set (Graph.PG.succ graph_toinstall pkg)
                 with _ -> set),
                OpamMisc.IntMap.add
                  (Graph.PG.V.hash pkg)
                  { cudf = pkg ; action = action_map package_map act } l_act in
              try
                let act = PkgMap.find pkg map_add in
                add_succ_rem pkg set_recompile act
              with Not_found ->
                if PkgSet.mem pkg set_recompile then
                  add_succ_rem pkg set_recompile (I_to_recompile pkg)
                else
                  set_recompile, l_act
            )
            graph_toinstall
            (PkgSet.empty, OpamMisc.IntMap.empty) in

        (** compute packages to recompile and remove *)
        let map_act, to_remove =
          let l_remove = Graph.topo_fold (create_graph "to-remove" (fun p -> PkgSet.mem p set_del)) set_del in

          (** partition the [l_remove] to decide for each element if we recompile them or delete. *)
          List.fold_left
            (fun (map_act, l_folded) pkg ->
              if
                (** check if the user has set some packages that will explicitely be removed *)
                List.exists
                  (fun (p, _) -> p = pkg.Cudf.package)
                  i_req.i_wish_remove
                ||
                  (** check if [pkg] contains an optional package which has already been visited in [l_folded] *)
                  List.exists
                  (fun p -> List.exists (fun p0 -> O_pkg.compare p0 p = 0) l_folded)
                  (try Graph.PG.succ graph_simple pkg with _ -> [])
              then
                (** [pkg] will be deleted *)
                map_act, (*package_map*) pkg :: l_folded
              else
                (** [pkg] will be recompiled *)
                OpamMisc.IntMap.add
                  (Graph.PG.V.hash pkg)
                  { cudf = pkg ; action = action_map package_map (I_to_recompile pkg) }
                  map_act,
                l_folded
            )
            (map_act, [])
            l_remove in

        (** construct the answer [graph] to add.
            Then, it suffices to fold it topologically
            by following the action given at each node (install or recompile). *)
        let graph = PA_graph.create () in
        OpamMisc.IntMap.iter (fun _ -> PA_graph.add_vertex graph) map_act;
        Graph.PG.iter_edges
          (fun v1 v2 ->
            try
              let v1 = OpamMisc.IntMap.find (Graph.PG.V.hash v1) map_act in
              let v2 = OpamMisc.IntMap.find (Graph.PG.V.hash v2) map_act in
              PA_graph.add_edge graph v1 v2
            with Not_found ->
              ())
          graph_toinstall;
        PA_graph.iter_update_reinstall ~installed graph;
        { to_remove = List.map package_map to_remove
        ; to_add = graph } in

      match sol_o with
      | Conflicts c -> Conflicts (fun () -> string_of_reasons table (c ()))
      | Success l   -> Success (action_of_answer l)
    )

let get_backward_dependencies = Graph.filter_backward_dependencies
let get_forward_dependencies = Graph.filter_forward_dependencies

let delete_or_update t =
  t.to_remove <> [] ||
  PA_graph.fold_vertex
    (fun v acc ->
      acc || match v.action with To_change (Some _, _) -> true | _ -> false)
    t.to_add
    false