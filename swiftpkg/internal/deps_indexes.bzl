"""Module for resolving module names to labels."""

load("@bazel_skylib//lib:sets.bzl", "sets")
load("@cgrindel_bazel_starlib//bzllib:defs.bzl", "bazel_labels", "lists")
load(":bazel_repo_names.bzl", "bazel_repo_names")
load(":pkginfo_targets.bzl", "pkginfo_targets")
load(":validations.bzl", "validations")

def _new_from_json(json_str):
    """Creates a module index from a JSON string.

    Args:
        json_str: A JSON `string` value.

    Returns:
        A `struct` that contains indexes for external dependencies.
    """
    mi = {}
    pi = {}

    # buildifier: disable=uninitialized
    def _add_module(m):
        entries = mi.get(m.name, [])
        entries.append(m)
        mi[m.name] = entries
        if m.name != m.c99name:
            entries = mi.get(m.c99name, [])
            entries.append(m)
            mi[m.c99name] = entries

    # buildifier: disable=uninitialized
    def _add_product(p):
        key = _new_product_index_key(p.identity, p.name)
        pi[key] = p

    orig_dict = json.decode(json_str)
    for mod_dict in orig_dict["modules"]:
        m = _new_module_from_dict(mod_dict)
        _add_module(m)
    for prod_dict in orig_dict["products"]:
        p = _new_product_from_dict(prod_dict)
        _add_product(p)
    return _new(
        modules = mi,
        products = pi,
    )

def _new(modules = {}, products = {}):
    return struct(
        modules = modules,
        products = products,
    )

def _new_module_from_dict(mod_dict):
    return _new_module(
        name = mod_dict["name"],
        c99name = mod_dict["c99name"],
        src_type = mod_dict.get("src_type", "unknown"),
        label = bazel_labels.parse(mod_dict["label"]),
    )

def _new_module(name, c99name, src_type, label):
    validations.in_list(
        src_types.all_values,
        src_type,
        "Unrecognized source type. type:",
    )
    return struct(
        name = name,
        c99name = c99name,
        src_type = src_type,
        label = label,
    )

def _new_product_from_dict(prd_dict):
    return _new_product(
        identity = prd_dict["identity"],
        name = prd_dict["name"],
        type = prd_dict["type"],
        target_labels = [
            bazel_labels.parse(lbl_str)
            for lbl_str in prd_dict["target_labels"]
        ],
    )

def _new_product(identity, name, type, target_labels):
    return struct(
        identity = identity,
        name = name,
        type = type,
        target_labels = target_labels,
    )

def _resolve_module_labels(
        deps_index,
        module_name,
        preferred_repo_name = None,
        restrict_to_repo_names = []):
    """Finds a Bazel label that provides the specified module.

    Args:
        deps_index: A `dict` as returned by `deps_indexes.new_from_json`.
        module_name: The name of the module as a `string`
        preferred_repo_name: Optional. If a target in this repository provides
            the module, prefer it.
        restrict_to_repo_names: Optional. A `list` of repository names to
            restrict the match.

    Returns:
        A `list` of `struct` values as returned by `bazel_labels.new`.
    """
    modules = deps_index.modules.get(module_name, [])
    if len(modules) == 0:
        return []
    labels = [m.label for m in modules]

    # If a repo name is provided, prefer that over any other matches
    if preferred_repo_name != None:
        preferred_repo_name = bazel_repo_names.normalize(preferred_repo_name)
        module = lists.find(
            modules,
            lambda m: m.label.repository_name == preferred_repo_name,
        )
        if module != None:
            # We found a match for the current/preferred repo. If the dep is an
            # objc, return the real Objective-C target, not the Swift module
            # alias. This is part of a workaround for Objective-C modules not
            # being able to `@import` modules from other Objective-C modules.
            # See `swiftpkg_build_files.bzl` for more information.
            if module.src_type == src_types.objc:
                return [
                    bazel_labels.new(
                        name = pkginfo_targets.objc_label_name(module.label.name),
                        repository_name = module.label.repository_name,
                        package = module.label.package,
                    ),
                ]
            else:
                return [module.label]

    # If we are meant to only find a match in a set of repo names, then
    if len(restrict_to_repo_names) > 0:
        restrict_to_repo_names = [
            bazel_repo_names.normalize(rn)
            for rn in restrict_to_repo_names
        ]
        repo_names = sets.make(restrict_to_repo_names)
        labels = [
            lbl
            for lbl in labels
            if sets.contains(repo_names, lbl.repository_name)
        ]

    # Only return the first label.
    if len(labels) == 0:
        return []
    return [labels[0]]

def _new_product_index_key(identity, name):
    return identity.lower() + "|" + name

def _find_product(deps_index, identity, name):
    """Retrieves the product based upon the identity and the name.

    Args:
        deps_index: A `dict` as returned by `deps_indexes.new_from_json`.
        identity: The dependency identity as a `string`.
        name: The product name as a `string`.

    Returns:
        A product `struct` as returned by `deps_indexes.new_product`. If not
        found, returns `None`.
    """
    key = _new_product_index_key(identity, name)
    return deps_index.products.get(key)

def _resolve_product_labels(deps_index, identity, name):
    """Returns the Bazel labels that represent the specified product.

    Args:
        deps_index: A `dict` as returned by `deps_indexes.new_from_json`.
        identity: The dependency identity as a `string`.
        name: The product name as a `string`.

    Returns:
        A `list` of Bazel label `struct` values as returned by
        `bazel_labels.new`. If the product is not found, an empty `list` is
        returned.
    """
    product = _find_product(deps_index, identity, name)
    if product == None:
        return []
    return product.target_labels

def _new_ctx(deps_index, preferred_repo_name = None, restrict_to_repo_names = []):
    """Create a new context struct that encapsulates a dependency index along with \
    select lookup criteria.

    Args:
        deps_index: A `dict` as returned by `deps_indexes.new_from_json`.
        preferred_repo_name: Optional. If a target in this repository provides
            the module, prefer it.
        restrict_to_repo_names: Optional. A `list` of repository names to
            restrict the match.

    Returns:
        A `struct` that encapsulates a module index along with select lookup
        criteria.
    """
    return struct(
        deps_index = deps_index,
        preferred_repo_name = preferred_repo_name,
        restrict_to_repo_names = restrict_to_repo_names,
    )

def _resolve_module_labels_with_ctx(deps_index_ctx, module_name):
    """Finds a Bazel label that provides the specified module.

    Args:
        deps_index_ctx: A `struct` as returned by `deps_indexes.new_ctx`.
        module_name: The name of the module as a `string`

    Returns:
        A `list` of `struct` values as returned by `bazel_labels.new`.
    """
    return _resolve_module_labels(
        deps_index = deps_index_ctx.deps_index,
        module_name = module_name,
        preferred_repo_name = deps_index_ctx.preferred_repo_name,
        restrict_to_repo_names = deps_index_ctx.restrict_to_repo_names,
    )

src_types = struct(
    unknown = "unknown",
    swift = "swift",
    clang = "clang",
    objc = "objc",
    binary = "binary",
    all_values = [
        "unknown",
        "swift",
        "clang",
        "objc",
        "binary",
    ],
)

deps_indexes = struct(
    find_product = _find_product,
    new = _new,
    new_ctx = _new_ctx,
    new_from_json = _new_from_json,
    new_module = _new_module,
    new_product = _new_product,
    resolve_module_labels = _resolve_module_labels,
    resolve_module_labels_with_ctx = _resolve_module_labels_with_ctx,
    resolve_product_labels = _resolve_product_labels,
)
