const DEFAULT_DEFAULT_BRANCH = "main"

"""
    Git(;
        ignore=String[],
        name=nothing,
        email=nothing,
        branch=LibGit2.getconfig("init.defaultBranch", "$DEFAULT_DEFAULT_BRANCH")
        ssh=false,
        jl=true,
        manifest=false,
        gpgsign=false,
    )

Creates a Git repository and a `.gitignore` file.

## Keyword Arguments
- `ignore::Vector{<:AbstractString}`: Patterns to add to the `.gitignore`.
  See also: [`gitignore`](@ref).
- `name::AbstractString`: Your real name, if you have not set `user.name` with Git.
- `email::AbstractString`: Your email address, if you have not set `user.email` with Git.
- `branch::AbstractString`: The desired name of the repository's default branch.
- `ssh::Bool`: Whether or not to use SSH for the remote.
  If left unset, HTTPS is used.
- `jl::Bool`: Whether or not to add a `.jl` suffix to the remote URL.
- `manifest::Bool`: Whether or not to commit `Manifest.toml`.
- `gpgsign::Bool`: Whether or not to sign commits with your GPG key.
  This option requires that the Git CLI is installed,
  and for you to have a GPG key associated with your committer identity.
"""
@plugin struct Git <: Plugin
    ignore::Vector{String} = String[]
    name::Union{String, Nothing} = nothing
    email::Union{String, Nothing} = nothing
    branch::String = @mock(LibGit2.getconfig("init.defaultBranch", DEFAULT_DEFAULT_BRANCH))
    ssh::Bool = false
    jl::Bool = true
    manifest::Bool = false
    gpgsign::Bool = false
end

# Try to make sure that no files are created after we commit.
priority(::Git, ::typeof(posthook)) = 5
gitignore(p::Git) = p.ignore

function validate(p::Git, t::Template)
    if p.gpgsign && !git_is_installed()
        throw(ArgumentError("Git: gpgsign is set but the Git CLI is not installed"))
    end

    foreach((:name, :email)) do k
        user_k = "user.$k"
        if getproperty(p, k) === nothing && isempty(@mock LibGit2.getconfig(user_k, ""))
            throw(ArgumentError("Git: Global Git config is missing required value '$user_k'"))
        end
    end
end

# Set up the Git repository.
function prehook(p::Git, t::Template, pkg_dir::AbstractString)
    LibGit2.with(@mock LibGit2.init(pkg_dir)) do repo
        LibGit2.with(GitConfig(repo)) do config
            foreach((:name, :email)) do k
                v = getproperty(p, k)
                v === nothing || LibGit2.set!(config, "user.$k", v)
            end
        end
        commit(p, repo, pkg_dir, "Initial commit")
        pkg = pkg_name(pkg_dir)
        suffix = p.jl ? ".jl" : ""
        url = if p.ssh
            "git@$(t.host):$(t.user)/$pkg$suffix.git"
        else
            "https://$(t.host)/$(t.user)/$pkg$suffix"
        end
        default = LibGit2.branch(repo)
        branch = something(p.branch, default)
        if branch != default
            LibGit2.branch!(repo, branch)
            delete_branch(GitReference(repo, "refs/heads/$default"))
        end
        close(GitRemote(repo, "origin", url))
    end
end

# Create the .gitignore.
function hook(p::Git, t::Template, pkg_dir::AbstractString)
    ignore = mapreduce(gitignore, vcat, t.plugins)
    # Only ignore manifests at the repo root.
    p.manifest || "Manifest.toml" in ignore || push!(ignore, "/Manifest.toml")
    unique!(sort!(ignore))
    gen_file(joinpath(pkg_dir, ".gitignore"), join(ignore, "\n"))
end

# Commit the files.
function posthook(p::Git, ::Template, pkg_dir::AbstractString)
    # Special case for issue 211.
    if Sys.iswindows()
        files = filter(f -> startswith(f, "_git2_"), readdir(pkg_dir))
        foreach(f -> rm(joinpath(pkg_dir, f)), files)
    end

    # Ensure that the manifest exists if it's going to be committed.
    manifest = joinpath(pkg_dir, "Manifest.toml")
    if p.manifest && !isfile(manifest)
        touch(manifest)
        with_project(Pkg.update, pkg_dir)
    end

    LibGit2.with(GitRepo(pkg_dir)) do repo
        LibGit2.add!(repo, ".")
        msg = "Files generated by PkgTemplates"
        v = @mock version_of("PkgTemplates")
        v === nothing || (msg *= "\n\nPkgTemplates version: $v")
        # TODO: Put the template config in the message too?
        commit(p, repo, pkg_dir, msg)
    end
end

function commit(p::Git, repo::GitRepo, pkg_dir::AbstractString, msg::AbstractString)
    if p.gpgsign
        run(pipeline(`git -C $pkg_dir commit -S --allow-empty -m $msg`; stdout=devnull))
    else
        LibGit2.commit(repo, msg)
    end
end

needs_username(::Git) = true

function git_is_installed()
    return try
        run(pipeline(`git --version`; stdout=devnull))
        true
    catch
        false
    end
end

if isdefined(Pkg, :dependencies)
    function version_of(pkg::AbstractString)
        for p in values(Pkg.dependencies())
            p.name == pkg && return p.version
        end
        return nothing
    end
else
    version_of(pkg::AbstractString) = get(Pkg.installed(), pkg, nothing)
end
