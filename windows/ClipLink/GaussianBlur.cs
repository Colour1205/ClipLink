using System.Runtime.InteropServices;
using Windows.Foundation;
using Windows.Graphics.Effects;
using WinRT;

namespace ClipLink;

// Direct2D's Gaussian blur, as a composition effect (for the list behind a card
// that zooms open: CardZoom). The compositor takes an effect description that
// also answers IGraphicsEffectD2D1Interop - what Win2D's effects do - and this
// is that, for the one effect, rather than Win2D and its native library in
// every install for it. Its amount can be animated, as "<Name>.BlurAmount".
internal sealed class GaussianBlur : IGraphicsEffect, IGraphicsEffectSource, ICustomQueryInterface
{
    public string Name { get; set; } = "Blur";
    public required IGraphicsEffectSource Source { get; init; }
    // Direct2D's standard deviation, in DIPs.
    public float BlurAmount { get; init; }

    // D2D1_GAUSSIANBLUR_PROP_*: STANDARD_DEVIATION, OPTIMIZATION, BORDER_MODE.
    private const uint Optimization = 1; // D2D1_GAUSSIANBLUR_OPTIMIZATION_BALANCED
    private const uint BorderMode = 1;   // D2D1_BORDER_MODE_HARD: the edges stay, not fade out

    private static readonly Guid EffectId = new("1FEB6D69-2FE6-4AC9-8C58-1D7F93E7A6A5"); // CLSID_D2D1GaussianBlur
    private static readonly Guid InteropIid = new("2FC57384-A068-44D7-A331-30982FCF7177"); // IGraphicsEffectD2D1Interop
    private static readonly Guid PropertyValueIid = new("4BD682DD-7554-40E9-9A9B-82654EDE7E62"); // IPropertyValue
    private static readonly Guid SourceIid = new("2D8F9DDC-4339-4EB9-9216-F9DEB75658A2"); // IGraphicsEffectSource

    private const int S_OK = 0;
    private const int E_INVALIDARG = unchecked((int)0x80070057);
    private const int E_NOINTERFACE = unchecked((int)0x80004002);
    private const int E_POINTER = unchecked((int)0x80004003);

    // The compositor asks the effect's own COM object for the interop
    // interface (ComWrappers passes that to ICustomQueryInterface): it gets a
    // small native object of its own, which keeps the effect alive.
    CustomQueryInterfaceResult ICustomQueryInterface.GetInterface(ref Guid iid, out IntPtr ppv)
    {
        if (iid == InteropIid)
        {
            ppv = Interop.Create(this);
            return CustomQueryInterfaceResult.Handled;
        }
        ppv = IntPtr.Zero;
        return CustomQueryInterfaceResult.NotHandled;
    }

    private int GetProperty(uint index, out IntPtr value)
    {
        value = IntPtr.Zero;
        object? boxed = index switch
        {
            0 => PropertyValue.CreateSingle(BlurAmount),
            1 => PropertyValue.CreateUInt32(Optimization),
            2 => PropertyValue.CreateUInt32(BorderMode),
            _ => null,
        };
        if (boxed == null) return E_INVALIDARG;
        IntPtr inspectable = MarshalInspectable<object>.FromManaged(boxed);
        try
        {
            return Marshal.QueryInterface(inspectable, in PropertyValueIid, out value);
        }
        finally
        {
            Marshal.Release(inspectable);
        }
    }

    private int GetSource(out IntPtr source)
    {
        source = IntPtr.Zero;
        IntPtr inspectable = MarshalInspectable<object>.FromManaged(Source);
        try
        {
            return Marshal.QueryInterface(inspectable, in SourceIid, out source);
        }
        finally
        {
            Marshal.Release(inspectable);
        }
    }

    // IGraphicsEffectD2D1Interop, by hand: a vtable of delegates (kept alive
    // here for good) and, per object, the vtable pointer and a handle to its
    // effect and reference count.
    private static class Interop
    {
        private sealed class Holder
        {
            public required GaussianBlur Effect;
            public int References = 1;
        }

        [UnmanagedFunctionPointer(CallingConvention.StdCall)] private delegate int QueryInterfaceFn(IntPtr self, ref Guid iid, out IntPtr ppv);
        [UnmanagedFunctionPointer(CallingConvention.StdCall)] private delegate uint RefFn(IntPtr self);
        [UnmanagedFunctionPointer(CallingConvention.StdCall)] private delegate int GuidFn(IntPtr self, out Guid id);
        [UnmanagedFunctionPointer(CallingConvention.StdCall)] private delegate int MappingFn(IntPtr self, IntPtr name, out uint index, out int mapping);
        [UnmanagedFunctionPointer(CallingConvention.StdCall)] private delegate int CountFn(IntPtr self, out uint count);
        [UnmanagedFunctionPointer(CallingConvention.StdCall)] private delegate int ItemFn(IntPtr self, uint index, out IntPtr item);

        private static readonly Delegate[] Methods =
        {
            new QueryInterfaceFn(QueryInterface),
            new RefFn(AddRef),
            new RefFn(Release),
            new GuidFn(GetEffectId),
            new MappingFn(GetNamedPropertyMapping),
            new CountFn(GetPropertyCount),
            new ItemFn(GetProperty),
            new ItemFn(GetSource),
            new CountFn(GetSourceCount),
        };

        private static readonly IntPtr Vtable = MakeVtable();

        private static IntPtr MakeVtable()
        {
            IntPtr table = Marshal.AllocHGlobal(IntPtr.Size * Methods.Length);
            for (int i = 0; i < Methods.Length; i++) Marshal.WriteIntPtr(table, i * IntPtr.Size, Marshal.GetFunctionPointerForDelegate(Methods[i]));
            return table;
        }

        public static IntPtr Create(GaussianBlur effect)
        {
            IntPtr self = Marshal.AllocHGlobal(IntPtr.Size * 2);
            Marshal.WriteIntPtr(self, 0, Vtable);
            Marshal.WriteIntPtr(self, IntPtr.Size, GCHandle.ToIntPtr(GCHandle.Alloc(new Holder { Effect = effect })));
            return self;
        }

        private static Holder HolderOf(IntPtr self) => (Holder)GCHandle.FromIntPtr(Marshal.ReadIntPtr(self, IntPtr.Size)).Target!;

        private static int QueryInterface(IntPtr self, ref Guid iid, out IntPtr ppv)
        {
            ppv = IntPtr.Zero;
            try
            {
                if (iid == InteropIid)
                {
                    AddRef(self);
                    ppv = self;
                    return S_OK;
                }
                // Anything else (IUnknown among them) is the effect's own.
                IntPtr inspectable = MarshalInspectable<object>.FromManaged(HolderOf(self).Effect);
                try
                {
                    return Marshal.QueryInterface(inspectable, in iid, out ppv);
                }
                finally
                {
                    Marshal.Release(inspectable);
                }
            }
            catch (Exception)
            {
                return E_NOINTERFACE;
            }
        }

        private static uint AddRef(IntPtr self) => (uint)Interlocked.Increment(ref HolderOf(self).References);

        private static uint Release(IntPtr self)
        {
            var holder = HolderOf(self);
            int left = Interlocked.Decrement(ref holder.References);
            if (left == 0)
            {
                GCHandle.FromIntPtr(Marshal.ReadIntPtr(self, IntPtr.Size)).Free();
                Marshal.FreeHGlobal(self);
            }
            return (uint)left;
        }

        private static int GetEffectId(IntPtr self, out Guid id)
        {
            id = EffectId;
            return S_OK;
        }

        // The names an animation can use: "<Name>.BlurAmount" and the rest.
        private static int GetNamedPropertyMapping(IntPtr self, IntPtr name, out uint index, out int mapping)
        {
            index = 0;
            mapping = 1; // GRAPHICS_EFFECT_PROPERTY_MAPPING_DIRECT
            if (name == IntPtr.Zero) return E_POINTER;
            switch (Marshal.PtrToStringUni(name)?.ToLowerInvariant())
            {
                case "bluramount": index = 0; return S_OK;
                case "optimization": index = 1; return S_OK;
                case "bordermode": index = 2; return S_OK;
                default: return E_INVALIDARG;
            }
        }

        private static int GetPropertyCount(IntPtr self, out uint count)
        {
            count = 3;
            return S_OK;
        }

        private static int GetProperty(IntPtr self, uint index, out IntPtr value)
        {
            try
            {
                return HolderOf(self).Effect.GetProperty(index, out value);
            }
            catch (Exception)
            {
                value = IntPtr.Zero;
                return E_INVALIDARG;
            }
        }

        private static int GetSource(IntPtr self, uint index, out IntPtr source)
        {
            source = IntPtr.Zero;
            if (index != 0) return E_INVALIDARG;
            try
            {
                return HolderOf(self).Effect.GetSource(out source);
            }
            catch (Exception)
            {
                return E_INVALIDARG;
            }
        }

        private static int GetSourceCount(IntPtr self, out uint count)
        {
            count = 1;
            return S_OK;
        }
    }
}
