/*
 * std_set.i stub for SWIG Octave target.
 *
 * SWIG's Octave library does not ship std_set.i (unlike the Python/Java/Ruby
 * targets). This stub is placed on the SWIG include path ahead of the system
 * library so that the shared templates.i can %include "std_set.i" without
 * error.
 *
 * We provide a minimal std::set template that lets the %template()
 * instantiations in templates.i compile. The resulting Octave wrapper does
 * not expose set iteration — which is fine, since ConfigSet / CapabilitySet
 * are not directly used from Octave scripts.
 */

namespace std {
    template<class T> class set {
    public:
        set();
        bool empty() const;
        size_t size() const;
        void clear();
        void insert(const T &val);
        void erase(const T &val);
    };
}
