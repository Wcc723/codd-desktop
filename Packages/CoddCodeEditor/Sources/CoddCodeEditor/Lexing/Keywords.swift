import Foundation

/// Keyword tables (built-in types and literals such as `true`, `nil`, `self` count as keywords:
/// the artboard has one amber class for all of them).
enum Keywords {
    private static func set(_ text: String) -> Set<String> {
        Set(text.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init))
    }

    static let javascript = set("""
        async await break case catch class const continue debugger default delete do else export extends
        false finally for from function get if import in instanceof let new null of return set static super
        switch this throw true try typeof undefined var void while with yield as
        """)
    static let typescript = javascript.union(set("""
        abstract any asserts bigint boolean declare enum implements infer interface is keyof module namespace
        never number object override private protected public readonly require satisfies string symbol type
        unique unknown accessor
        """))
    /// After these a `/` starts a regular expression and a `<` a JSX element.
    static let jsExpressionKeywords = set("return typeof instanceof in of new delete void throw case do else yield await")
    static let swift = set("""
        associatedtype class deinit enum extension fileprivate func import init inout internal let open operator
        private precedencegroup protocol public rethrows static struct subscript typealias var break case catch
        continue default defer do else fallthrough for guard if in repeat return throw switch where while as
        Any false is nil self Self super throws true try await async actor nonisolated isolated some any
        consuming borrowing sending package macro convenience dynamic final lazy mutating nonmutating optional
        override required unowned weak willSet didSet get set indirect Int Double String Bool Float Void
        Character UInt Array Dictionary Optional
        """)
    static let go = set("""
        break case chan const continue default defer else fallthrough for func go goto if import interface map
        package range return select struct switch type var true false nil iota bool byte complex64 complex128
        error float32 float64 int int8 int16 int32 int64 rune string uint uint8 uint16 uint32 uint64 uintptr any
        """)
    static let rust = set("""
        as async await break const continue crate dyn else enum extern false fn for if impl in let loop match mod
        move mut pub ref return self Self static struct super trait true type unsafe use where while union
        i8 i16 i32 i64 i128 isize u8 u16 u32 u64 u128 usize f32 f64 bool char str String Option Some None Result
        Ok Err Box Vec
        """)
    static let c = set("""
        auto break case char const continue default do double else enum extern float for goto if inline int long
        register restrict return short signed sizeof static struct switch typedef union unsigned void volatile
        while _Bool _Complex _Atomic _Noreturn bool true false NULL size_t uint8_t uint16_t uint32_t uint64_t
        int8_t int16_t int32_t int64_t
        """)
    static let cpp = c.union(set("""
        alignas alignof and asm catch class constexpr consteval constinit const_cast decltype delete dynamic_cast
        explicit export friend mutable namespace new noexcept not nullptr operator or private protected public
        reinterpret_cast static_assert static_cast template this thread_local throw try typeid typename using
        virtual wchar_t override final concept requires co_await co_return co_yield std string vector
        """))
    static let objc = c.union(set("""
        id instancetype self super nil Nil YES NO BOOL SEL IMP Class nonatomic atomic strong weak assign copy
        readonly readwrite nullable nonnull retain unsafe_unretained __weak __strong __block
        """))
    /// `@interface` & co. (the `@` is part of the keyword).
    static let objcAt = set("""
        interface implementation end protocol property synthesize dynamic class selector encode optional required
        public private protected package try catch finally throw autoreleasepool synchronized import available
        """)
    static let java = set("""
        abstract assert boolean break byte case catch char class const continue default do double else enum extends
        final finally float for goto if implements import instanceof int interface long native new package private
        protected public return short static strictfp super switch synchronized this throw throws transient try
        void volatile while true false null var record sealed permits yield non-sealed String
        """)
    static let kotlin = set("""
        as break class continue do else false for fun if in interface is null object package return super this
        throw true try typealias typeof val var when while by catch constructor delegate dynamic field file
        finally get import init param property receiver set setparam where actual abstract annotation companion
        const crossinline data enum expect external final infix inline inner internal lateinit noinline open
        operator out override private protected public reified sealed suspend tailrec vararg value Int Long
        String Boolean Unit Any Nothing Double Float List Map
        """)
    static let php = set("""
        abstract and array as break callable case catch class clone const continue declare default do echo else
        elseif empty enddeclare endfor endforeach endif endswitch endwhile enum eval exit extends final finally fn
        for foreach function global goto if implements include include_once instanceof insteadof interface isset
        list match namespace new or print private protected public readonly require require_once return static
        switch throw trait try unset use var while xor yield true false null self parent int float bool string
        void mixed never iterable object
        """)
    static let python = set("""
        False None True and as assert async await break class continue def del elif else except finally for from
        global if import in is lambda nonlocal not or pass raise return try while with yield match case self cls
        print
        """)
    static let ruby = set("""
        BEGIN END alias and begin break case class def defined? do else elsif end ensure false for if in module
        next nil not or redo rescue retry return self super then true undef unless until when while yield
        require require_relative include extend prepend attr_accessor attr_reader attr_writer private protected
        public raise loop lambda proc puts
        """)
    static let shell = set("""
        if then else elif fi case esac for select while until do done in function time coproc
        """)
    static let shellBuiltins = set("""
        echo printf read cd pwd pushd popd export unset local declare typeset readonly return exit source alias
        unalias set shift trap wait eval exec test true false getopts command builtin type hash ulimit umask
        kill jobs bg fg disown let mapfile sudo
        """)
    static let sql = set("""
        select from where insert into values update set delete create table alter drop index view join left right
        inner outer full cross on as and or not null is in exists between like ilike group by order having limit
        offset union all distinct case when then else end primary key foreign references default unique check
        constraint if begin commit rollback transaction returning with recursive asc desc true false integer int
        text varchar char boolean date timestamp serial bigint real float double numeric decimal blob json jsonb
        trigger function procedure returns language declare grant revoke cascade replace temp temporary explain
        analyze vacuum pragma over partition window filter using natural add column database schema to cast
        coalesce nulls first last fetch next rows only do nothing conflict lateral
        """)
}
