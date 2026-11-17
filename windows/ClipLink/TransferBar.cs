using System.Numerics;
using Microsoft.UI.Composition;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Hosting;
using Microsoft.UI.Xaml.Media;

namespace ClipLink;

// The thin bar under a file that is arriving (Synced page). Not a ProgressBar:
// its fill has to move at an even pace to each new value, over the quarter
// second until the next one, not jump or ease in and out. The fill is scaled
// by the compositor, so moving it never lays the card out again. A value
// lower than before (the sender started over) jumps there, and so does
// every change with animations turned off in Windows.
//
// Background is the track; Fill the part that has arrived.
public sealed class TransferBar : Grid
{
    private const int MoveMs = 250;
    private readonly Border fill = new() { HorizontalAlignment = HorizontalAlignment.Stretch };
    private Visual? fillVisual;
    private double shown;

    public TransferBar()
    {
        Children.Add(fill);
        // (Scaled from its left end, so a card that changes width needs nothing.)
        Loaded += (_, _) => Show(Value, animate: false);
    }

    public static readonly DependencyProperty ValueProperty = DependencyProperty.Register(
        nameof(Value), typeof(double), typeof(TransferBar), new PropertyMetadata(0.0, (bar, e) => ((TransferBar)bar).Show((double)e.NewValue, animate: true)));

    // How much has arrived, 0 to 1.
    public double Value
    {
        get => (double)GetValue(ValueProperty);
        set => SetValue(ValueProperty, value);
    }

    public static readonly DependencyProperty FillProperty = DependencyProperty.Register(
        nameof(Fill), typeof(Brush), typeof(TransferBar), new PropertyMetadata(null, (bar, e) => ((TransferBar)bar).fill.Background = (Brush?)e.NewValue));

    public Brush? Fill
    {
        get => (Brush?)GetValue(FillProperty);
        set => SetValue(FillProperty, value);
    }

    private void Show(double value, bool animate)
    {
        value = double.IsNaN(value) ? 0 : Math.Clamp(value, 0, 1);
        try
        {
            fillVisual ??= ElementCompositionPreview.GetElementVisual(fill);
            fillVisual.CenterPoint = Vector3.Zero;
            bool move = animate && IsLoaded && value > shown && MotionPreference.Enabled;
            shown = value;
            if (!move)
            {
                fillVisual.StopAnimation("Scale.X");
                fillVisual.Scale = new Vector3((float)value, 1, 1);
                return;
            }
            var compositor = fillVisual.Compositor;
            var grow = compositor.CreateScalarKeyFrameAnimation();
            grow.InsertKeyFrame(1f, (float)value, compositor.CreateLinearEasingFunction());
            grow.Duration = TimeSpan.FromMilliseconds(MoveMs);
            fillVisual.StartAnimation("Scale.X", grow);
        }
        catch (Exception ex)
        {
            // Only the movement is lost.
            Console.WriteLine($"[app] progress bar failed: {ex.Message}");
        }
    }
}
