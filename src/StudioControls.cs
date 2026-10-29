using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;

namespace SessionRecovery.Studio
{
    internal static class Draw
    {
        public static GraphicsPath RoundRect(Rectangle rect, int radius)
        {
            GraphicsPath path = new GraphicsPath();
            int diameter = radius * 2;
            if (diameter > rect.Width) diameter = rect.Width;
            if (diameter > rect.Height) diameter = rect.Height;
            if (diameter <= 0)
            {
                path.AddRectangle(rect);
                return path;
            }
            path.AddArc(rect.X, rect.Y, diameter, diameter, 180, 90);
            path.AddArc(rect.Right - diameter, rect.Y, diameter, diameter, 270, 90);
            path.AddArc(rect.Right - diameter, rect.Bottom - diameter, diameter, diameter, 0, 90);
            path.AddArc(rect.X, rect.Bottom - diameter, diameter, diameter, 90, 90);
            path.CloseFigure();
            return path;
        }

        public static void FillRoundRect(Graphics graphics, Rectangle rect, int radius, Color color)
        {
            using (GraphicsPath path = RoundRect(rect, radius))
            using (SolidBrush brush = new SolidBrush(color))
            {
                graphics.FillPath(brush, path);
            }
        }

        public static void DrawRoundRect(Graphics graphics, Rectangle rect, int radius, Color color, float width)
        {
            using (GraphicsPath path = RoundRect(rect, radius))
            using (Pen pen = new Pen(color, width))
            {
                graphics.DrawPath(pen, path);
            }
        }
    }

    public class StudioCard : Panel
    {
        private Color _fillColor = Color.FromArgb(18, 25, 36);
        private Color _borderColor = Color.FromArgb(34, 45, 61);
        private Color _canvasColor = Color.FromArgb(8, 12, 18);
        private int _cornerRadius = 14;

        public Color FillColor
        {
            get { return _fillColor; }
            set { _fillColor = value; BackColor = value; Invalidate(); }
        }

        public Color BorderColor
        {
            get { return _borderColor; }
            set { _borderColor = value; Invalidate(); }
        }

        public Color CanvasColor
        {
            get { return _canvasColor; }
            set { _canvasColor = value; Invalidate(); }
        }

        public int CornerRadius
        {
            get { return _cornerRadius; }
            set { _cornerRadius = value; Invalidate(); }
        }

        public StudioCard()
        {
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw | ControlStyles.UserPaint, true);
            BackColor = _fillColor;
            Padding = new Padding(1);
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            e.Graphics.Clear(_canvasColor);
            Rectangle rect = new Rectangle(0, 0, Width - 1, Height - 1);
            using (GraphicsPath path = Draw.RoundRect(rect, _cornerRadius))
            using (SolidBrush brush = new SolidBrush(_fillColor))
            using (Pen pen = new Pen(_borderColor))
            {
                e.Graphics.FillPath(brush, path);
                e.Graphics.DrawPath(pen, path);
            }
        }
    }

    public class StudioSnapshotRow : StudioCard
    {
        private static readonly Font TimeFont = new Font("Segoe UI Semibold", 9.5f, FontStyle.Regular, GraphicsUnit.Point);
        private static readonly Font MetaFont = new Font("Segoe UI", 8.25f, FontStyle.Regular, GraphicsUnit.Point);
        private static readonly Font GlyphFont = new Font("Segoe MDL2 Assets", 10f, FontStyle.Regular, GraphicsUnit.Point);
        private string _timeText = "";
        private string _metaText = "";
        private string _ageText = "";
        private string _approxLabel = "APPROX";
        private string _pinnedLabel = "PINNED";
        private bool _approximate;
        private bool _pinned;
        private bool _selected;
        private Color _textColor = Color.FromArgb(238, 244, 252);
        private Color _mutedColor = Color.FromArgb(151, 164, 181);
        private Color _subtleColor = Color.FromArgb(116, 132, 151);
        private Color _accentColor = Color.FromArgb(108, 99, 255);
        private Color _amberColor = Color.FromArgb(245, 184, 78);
        private Color _amberSoft = Color.FromArgb(55, 45, 26);
        private Color _pinnedSoft = Color.FromArgb(31, 31, 61);

        public string TimeText { get { return _timeText; } set { _timeText = value ?? ""; Invalidate(); } }
        public string MetaText { get { return _metaText; } set { _metaText = value ?? ""; Invalidate(); } }
        public string AgeText { get { return _ageText; } set { _ageText = value ?? ""; Invalidate(); } }
        public string ApproxLabel { get { return _approxLabel; } set { _approxLabel = string.IsNullOrWhiteSpace(value) ? "APPROX" : value; Invalidate(); } }
        public string PinnedLabel { get { return _pinnedLabel; } set { _pinnedLabel = string.IsNullOrWhiteSpace(value) ? "PINNED" : value; Invalidate(); } }
        public bool Approximate { get { return _approximate; } set { _approximate = value; Invalidate(); } }
        public bool Pinned { get { return _pinned; } set { _pinned = value; Invalidate(); } }
        public bool Selected { get { return _selected; } set { _selected = value; Invalidate(); } }
        public Color TextColor { get { return _textColor; } set { _textColor = value; Invalidate(); } }
        public Color MutedColor { get { return _mutedColor; } set { _mutedColor = value; Invalidate(); } }
        public Color SubtleColor { get { return _subtleColor; } set { _subtleColor = value; Invalidate(); } }
        public Color AccentColor { get { return _accentColor; } set { _accentColor = value; Invalidate(); } }
        public Color AmberColor { get { return _amberColor; } set { _amberColor = value; Invalidate(); } }
        public Color AmberSoft { get { return _amberSoft; } set { _amberSoft = value; Invalidate(); } }
        public Color PinnedSoft { get { return _pinnedSoft; } set { _pinnedSoft = value; Invalidate(); } }

        public StudioSnapshotRow()
        {
            Cursor = Cursors.Hand;
            CornerRadius = 10;
            Padding = new Padding(1);
            TabStop = true;
            AccessibleRole = AccessibleRole.ListItem;
        }

        protected override void OnKeyDown(KeyEventArgs e)
        {
            if (e.KeyCode == Keys.Enter || e.KeyCode == Keys.Space)
            {
                OnClick(EventArgs.Empty);
                e.Handled = true;
                return;
            }
            base.OnKeyDown(e);
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            base.OnPaint(e);
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            int textWidth = Math.Max(80, Width - 120);
            TextRenderer.DrawText(e.Graphics, _timeText, TimeFont, new Rectangle(14, 8, textWidth, 18), _textColor, TextFormatFlags.Left | TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine | TextFormatFlags.EndEllipsis);
            TextRenderer.DrawText(e.Graphics, _metaText, MetaFont, new Rectangle(14, 29, textWidth, 16), _mutedColor, TextFormatFlags.Left | TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine | TextFormatFlags.EndEllipsis);
            TextRenderer.DrawText(e.Graphics, _ageText, MetaFont, new Rectangle(14, 45, 200, 14), _subtleColor, TextFormatFlags.Left | TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine | TextFormatFlags.EndEllipsis);
            if (_approximate)
            {
                int approxWidth = Math.Max(58, TextRenderer.MeasureText(_approxLabel, MetaFont, new Size(int.MaxValue, 18), TextFormatFlags.NoPadding).Width + 12);
                Rectangle badge = new Rectangle(Math.Max(82, Width - 44 - approxWidth), 8, approxWidth, 18);
                Draw.FillRoundRect(e.Graphics, badge, 5, _amberSoft);
                TextRenderer.DrawText(e.Graphics, _approxLabel, MetaFont, badge, _amberColor, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPadding);
            }
            if (_pinned)
            {
                int pinnedWidth = Math.Max(60, TextRenderer.MeasureText(_pinnedLabel, MetaFont, new Size(int.MaxValue, 18), TextFormatFlags.NoPadding).Width + 12);
                Rectangle badge = new Rectangle(Math.Max(82, Width - 36 - pinnedWidth), 43, pinnedWidth, 18);
                Draw.FillRoundRect(e.Graphics, badge, 5, _pinnedSoft);
                TextRenderer.DrawText(e.Graphics, _pinnedLabel, MetaFont, badge, _accentColor, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPadding);
            }
            Rectangle chevron = new Rectangle(Width - 34, 22, 20, 20);
            TextRenderer.DrawText(e.Graphics, "\uE76C", GlyphFont, chevron, _subtleColor, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPadding);
            if (_selected)
            {
                using (Pen accent = new Pen(_accentColor, 1.5f))
                {
                    using (GraphicsPath path = Draw.RoundRect(new Rectangle(0, 0, Width - 1, Height - 1), CornerRadius))
                    {
                        e.Graphics.DrawPath(accent, path);
                    }
                }
            }
            if (Focused)
            {
                ControlPaint.DrawFocusRectangle(e.Graphics, new Rectangle(5, 5, Width - 10, Height - 10), _textColor, Color.Transparent);
            }
        }
    }

    public class StudioButton : Button
    {
        private bool _hover;
        private bool _pressed;
        private Color _fillColor = Color.FromArgb(94, 92, 230);
        private Color _gradientEndColor = Color.FromArgb(51, 181, 229);
        private Color _hoverColor = Color.FromArgb(110, 108, 245);
        private Color _pressedColor = Color.FromArgb(76, 74, 200);
        private Color _outlineColor = Color.Empty;
        private Color _textColor = Color.White;
        private Color _disabledFillColor = Color.FromArgb(44, 52, 65);
        private Color _disabledTextColor = Color.FromArgb(131, 143, 160);
        private int _cornerRadius = 10;

        public Color FillColor { get { return _fillColor; } set { _fillColor = value; Invalidate(); } }
        public Color GradientEndColor { get { return _gradientEndColor; } set { _gradientEndColor = value; Invalidate(); } }
        public Color HoverColor { get { return _hoverColor; } set { _hoverColor = value; Invalidate(); } }
        public Color PressedColor { get { return _pressedColor; } set { _pressedColor = value; Invalidate(); } }
        public Color OutlineColor { get { return _outlineColor; } set { _outlineColor = value; Invalidate(); } }
        public Color TextColor { get { return _textColor; } set { _textColor = value; Invalidate(); } }
        public Color DisabledFillColor { get { return _disabledFillColor; } set { _disabledFillColor = value; Invalidate(); } }
        public Color DisabledTextColor { get { return _disabledTextColor; } set { _disabledTextColor = value; Invalidate(); } }
        public int CornerRadius { get { return _cornerRadius; } set { _cornerRadius = value; Invalidate(); } }
        public string Glyph { get; set; }
        public float GlyphSize { get; set; }

        public StudioButton()
        {
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw | ControlStyles.UserPaint, true);
            FlatStyle = FlatStyle.Flat;
            FlatAppearance.BorderSize = 0;
            Cursor = Cursors.Hand;
            Font = new Font("Segoe UI Semibold", 9.5f, FontStyle.Regular, GraphicsUnit.Point);
            UseVisualStyleBackColor = false;
            ForeColor = Color.White;
            Glyph = "";
            GlyphSize = 12f;
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            Color canvas = Parent != null ? Parent.BackColor : Color.FromArgb(8, 12, 18);
            e.Graphics.Clear(canvas);
            Rectangle rect = new Rectangle(0, 0, Width - 1, Height - 1);
            Color fill = !Enabled ? _disabledFillColor : (_pressed ? _pressedColor : (_hover ? _hoverColor : _fillColor));
            using (GraphicsPath path = Draw.RoundRect(rect, _cornerRadius))
            {
                if (Enabled && !_gradientEndColor.IsEmpty && _gradientEndColor != _fillColor)
                {
                    using (LinearGradientBrush brush = new LinearGradientBrush(rect, fill, _gradientEndColor, 0f))
                    {
                        e.Graphics.FillPath(brush, path);
                    }
                }
                else
                {
                    using (SolidBrush brush = new SolidBrush(fill))
                    {
                        e.Graphics.FillPath(brush, path);
                    }
                }
                if (!_outlineColor.IsEmpty)
                {
                    using (Pen pen = new Pen(_outlineColor))
                    {
                        e.Graphics.DrawPath(pen, path);
                    }
                }
            }

            Color text = Enabled ? _textColor : _disabledTextColor;
            int left = 0;
            if (!String.IsNullOrEmpty(Glyph))
            {
                using (Font glyphFont = new Font("Segoe MDL2 Assets", GlyphSize, FontStyle.Regular, GraphicsUnit.Point))
                {
                    Rectangle glyphRect = new Rectangle(14, 0, 20, Height);
                    TextRenderer.DrawText(e.Graphics, Glyph, glyphFont, glyphRect, text, TextFormatFlags.VerticalCenter | TextFormatFlags.Left | TextFormatFlags.NoPadding);
                }
                left = 34;
            }
            Rectangle textRect = new Rectangle(left, 0, Width - left - 6, Height);
            TextRenderer.DrawText(e.Graphics, Text, Font, textRect, text, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine | TextFormatFlags.EndEllipsis);
            if (Focused) ControlPaint.DrawFocusRectangle(e.Graphics, Rectangle.Inflate(rect, -4, -4), text, fill);
        }

        protected override void OnMouseEnter(EventArgs e) { _hover = true; Invalidate(); base.OnMouseEnter(e); }
        protected override void OnMouseLeave(EventArgs e) { _hover = false; _pressed = false; Invalidate(); base.OnMouseLeave(e); }
        protected override void OnMouseDown(MouseEventArgs e) { if (e.Button == MouseButtons.Left) { _pressed = true; Invalidate(); } base.OnMouseDown(e); }
        protected override void OnMouseUp(MouseEventArgs e) { _pressed = false; Invalidate(); base.OnMouseUp(e); }
        protected override void OnEnabledChanged(EventArgs e) { Invalidate(); base.OnEnabledChanged(e); }
    }

    public class StudioNavButton : Button
    {
        private bool _hover;
        private bool _selected;
        private Color _selectedFill = Color.FromArgb(27, 38, 54);
        private Color _hoverFill = Color.FromArgb(20, 29, 42);
        private Color _accentColor = Color.FromArgb(108, 99, 255);
        private Color _textColor = Color.FromArgb(151, 164, 181);
        private Color _selectedTextColor = Color.FromArgb(238, 244, 252);

        public string Glyph { get; set; }
        public bool Selected { get { return _selected; } set { _selected = value; Invalidate(); } }
        public Color SelectedFill { get { return _selectedFill; } set { _selectedFill = value; Invalidate(); } }
        public Color HoverFill { get { return _hoverFill; } set { _hoverFill = value; Invalidate(); } }
        public Color AccentColor { get { return _accentColor; } set { _accentColor = value; Invalidate(); } }
        public Color TextColor { get { return _textColor; } set { _textColor = value; Invalidate(); } }
        public Color SelectedTextColor { get { return _selectedTextColor; } set { _selectedTextColor = value; Invalidate(); } }

        public StudioNavButton()
        {
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw | ControlStyles.UserPaint, true);
            FlatStyle = FlatStyle.Flat;
            FlatAppearance.BorderSize = 0;
            Cursor = Cursors.Hand;
            Font = new Font("Segoe UI", 9.5f, FontStyle.Regular, GraphicsUnit.Point);
            UseVisualStyleBackColor = false;
            Glyph = "";
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            Color canvas = Parent != null ? Parent.BackColor : Color.FromArgb(11, 16, 24);
            e.Graphics.Clear(canvas);
            Rectangle rect = new Rectangle(0, 0, Width - 1, Height - 1);
            Color fill = _selected ? _selectedFill : (_hover ? _hoverFill : Color.Empty);
            if (!fill.IsEmpty)
            {
                using (GraphicsPath path = Draw.RoundRect(rect, 9))
                using (SolidBrush brush = new SolidBrush(fill))
                {
                    e.Graphics.FillPath(brush, path);
                }
            }
            if (_selected)
            {
                using (SolidBrush accent = new SolidBrush(_accentColor))
                {
                    e.Graphics.FillRectangle(accent, 0, 9, 3, Height - 18);
                }
            }
            Color textColor = _selected ? _selectedTextColor : _textColor;
            if (!String.IsNullOrEmpty(Glyph))
            {
                using (Font glyphFont = new Font("Segoe MDL2 Assets", 12f, FontStyle.Regular, GraphicsUnit.Point))
                {
                    Rectangle glyphRect = new Rectangle(15, 0, 22, Height);
                    TextRenderer.DrawText(e.Graphics, Glyph, glyphFont, glyphRect, textColor, TextFormatFlags.VerticalCenter | TextFormatFlags.Left | TextFormatFlags.NoPadding);
                }
            }
            Rectangle textRect = new Rectangle(46, 0, Width - 52, Height);
            TextRenderer.DrawText(e.Graphics, Text, Font, textRect, textColor, TextFormatFlags.VerticalCenter | TextFormatFlags.Left | TextFormatFlags.SingleLine | TextFormatFlags.EndEllipsis);
        }

        protected override void OnMouseEnter(EventArgs e) { _hover = true; Invalidate(); base.OnMouseEnter(e); }
        protected override void OnMouseLeave(EventArgs e) { _hover = false; Invalidate(); base.OnMouseLeave(e); }
    }

    public class StudioToggle : CheckBox
    {
        private Color _onColor = Color.FromArgb(94, 92, 230);
        private Color _offColor = Color.FromArgb(45, 55, 70);
        private Color _thumbColor = Color.White;

        public Color OnColor { get { return _onColor; } set { _onColor = value; Invalidate(); } }
        public Color OffColor { get { return _offColor; } set { _offColor = value; Invalidate(); } }
        public Color ThumbColor { get { return _thumbColor; } set { _thumbColor = value; Invalidate(); } }

        public StudioToggle()
        {
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw | ControlStyles.UserPaint | ControlStyles.SupportsTransparentBackColor, true);
            AutoSize = false;
            Size = new Size(46, 26);
            Cursor = Cursors.Hand;
            Text = "";
            BackColor = Color.Transparent;
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            Color canvas = Parent != null ? Parent.BackColor : Color.FromArgb(18, 25, 36);
            e.Graphics.Clear(canvas);
            int height = Math.Min(24, Height - 2);
            int width = Math.Min(44, Width - 2);
            Rectangle track = new Rectangle((Width - width) / 2, (Height - height) / 2, width, height);
            using (GraphicsPath path = Draw.RoundRect(track, height / 2))
            using (SolidBrush brush = new SolidBrush(Checked ? _onColor : _offColor))
            {
                e.Graphics.FillPath(brush, path);
            }
            int thumbSize = height - 6;
            int thumbX = Checked ? track.Right - thumbSize - 3 : track.Left + 3;
            using (SolidBrush thumb = new SolidBrush(_thumbColor))
            {
                e.Graphics.FillEllipse(thumb, thumbX, track.Top + 3, thumbSize, thumbSize);
            }
        }

        protected override void OnCheckedChanged(EventArgs e) { Invalidate(); base.OnCheckedChanged(e); }
    }

    public class StudioStatCard : StudioCard
    {
        private string _title = "";
        private string _value = "";
        private string _detail = "";
        private string _glyph = "";
        private Color _accentColor = Color.FromArgb(108, 99, 255);
        private Color _titleColor = Color.FromArgb(130, 145, 165);
        private Color _valueColor = Color.FromArgb(238, 244, 252);
        private Color _detailColor = Color.FromArgb(116, 132, 151);
        private Font _titleFont = new Font("Segoe UI", 8f, FontStyle.Regular, GraphicsUnit.Point);
        private Font _valueFont = new Font("Segoe UI Semibold", 20f, FontStyle.Regular, GraphicsUnit.Point);
        private Font _detailFont = new Font("Segoe UI", 8.25f, FontStyle.Regular, GraphicsUnit.Point);
        private Font _glyphFont = new Font("Segoe MDL2 Assets", 16f, FontStyle.Regular, GraphicsUnit.Point);

        public string Title { get { return _title; } set { _title = value; Invalidate(); } }
        public string Value { get { return _value; } set { _value = value; Invalidate(); } }
        public string Detail { get { return _detail; } set { _detail = value; Invalidate(); } }
        public string Glyph { get { return _glyph; } set { _glyph = value; Invalidate(); } }
        public Color AccentColor { get { return _accentColor; } set { _accentColor = value; Invalidate(); } }
        public Color TitleColor { get { return _titleColor; } set { _titleColor = value; Invalidate(); } }
        public Color ValueColor { get { return _valueColor; } set { _valueColor = value; Invalidate(); } }
        public Color DetailColor { get { return _detailColor; } set { _detailColor = value; Invalidate(); } }

        public StudioStatCard()
        {
            SetStyle(ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            base.OnPaint(e);
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            Rectangle iconRect = new Rectangle(18, 17, 36, 36);
            using (GraphicsPath path = Draw.RoundRect(iconRect, 9))
            using (SolidBrush brush = new SolidBrush(Color.FromArgb(30, _accentColor)))
            {
                e.Graphics.FillPath(brush, path);
            }
            TextRenderer.DrawText(e.Graphics, _glyph, _glyphFont, iconRect, _accentColor, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPadding);
            // Translated stat labels are longer than the English originals.
            // Wrap the title and detail instead of ellipsizing them, so every
            // language stays fully readable at the minimum window size.
            TextRenderer.DrawText(e.Graphics, _title.ToUpperInvariant(), _titleFont, new Rectangle(58, 6, Width - 70, 30), _titleColor, TextFormatFlags.Left | TextFormatFlags.Top | TextFormatFlags.WordBreak | TextFormatFlags.NoPadding);
            TextRenderer.DrawText(e.Graphics, _value, _valueFont, new Rectangle(60, 34, Width - 72, 34), _valueColor, TextFormatFlags.Left | TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis);
            TextRenderer.DrawText(e.Graphics, _detail, _detailFont, new Rectangle(18, 70, Width - 36, 36), _detailColor, TextFormatFlags.Left | TextFormatFlags.Top | TextFormatFlags.WordBreak | TextFormatFlags.NoPadding);
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing)
            {
                _titleFont.Dispose(); _valueFont.Dispose(); _detailFont.Dispose(); _glyphFont.Dispose();
            }
            base.Dispose(disposing);
        }
    }

    public class StudioRing : Control
    {
        private int _value;
        private Color _trackColor = Color.FromArgb(34, 45, 61);
        private Color _progressColor = Color.FromArgb(108, 99, 255);
        private Color _progressEndColor = Color.FromArgb(51, 181, 229);
        private Color _centerTextColor = Color.FromArgb(238, 244, 252);
        private Color _captionColor = Color.FromArgb(126, 143, 164);
        private string _centerText = "";
        private string _caption = "";
        private int _thickness = 8;
        private Font _centerFont = new Font("Segoe UI Semibold", 18f, FontStyle.Regular, GraphicsUnit.Point);
        private Font _captionFont = new Font("Segoe UI", 7.5f, FontStyle.Regular, GraphicsUnit.Point);

        public int Value { get { return _value; } set { _value = Math.Max(0, Math.Min(100, value)); Invalidate(); } }
        public Color TrackColor { get { return _trackColor; } set { _trackColor = value; Invalidate(); } }
        public Color ProgressColor { get { return _progressColor; } set { _progressColor = value; Invalidate(); } }
        public Color ProgressEndColor { get { return _progressEndColor; } set { _progressEndColor = value; Invalidate(); } }
        public Color CenterTextColor { get { return _centerTextColor; } set { _centerTextColor = value; Invalidate(); } }
        public Color CaptionColor { get { return _captionColor; } set { _captionColor = value; Invalidate(); } }
        public string CenterText { get { return _centerText; } set { _centerText = value; Invalidate(); } }
        public string Caption { get { return _caption; } set { _caption = value; Invalidate(); } }
        public int Thickness { get { return _thickness; } set { _thickness = value; Invalidate(); } }

        public StudioRing()
        {
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw | ControlStyles.UserPaint | ControlStyles.SupportsTransparentBackColor, true);
            BackColor = Color.Transparent;
            Size = new Size(130, 130);
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            Color canvas = Parent != null ? Parent.BackColor : Color.FromArgb(18, 25, 36);
            e.Graphics.Clear(canvas);
            int size = Math.Min(Width, Height) - _thickness - 4;
            Rectangle rect = new Rectangle((Width - size) / 2, (Height - size) / 2, size, size);
            using (Pen track = new Pen(_trackColor, _thickness))
            {
                track.StartCap = LineCap.Round; track.EndCap = LineCap.Round;
                e.Graphics.DrawArc(track, rect, -90, 360);
            }
            float sweep = 360f * (float)_value / 100f;
            if (sweep > 0)
            {
                using (LinearGradientBrush brush = new LinearGradientBrush(rect, _progressColor, _progressEndColor, 45f))
                using (Pen progress = new Pen(brush, _thickness))
                {
                    progress.StartCap = LineCap.Round; progress.EndCap = LineCap.Round;
                    e.Graphics.DrawArc(progress, rect, -90, sweep);
                }
            }
            TextRenderer.DrawText(e.Graphics, _centerText, _centerFont, rect, _centerTextColor, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPadding);
            if (!String.IsNullOrEmpty(_caption))
            {
                // Long ring captions ("LETZTER SCHNAPPSCHUSS") wrap onto a
                // second line rather than being cut off inside the ring.
                Rectangle captionRect = new Rectangle(rect.Left, rect.Top + (rect.Height / 2) + 16, rect.Width, 30);
                TextRenderer.DrawText(e.Graphics, _caption.ToUpperInvariant(), _captionFont, captionRect, _captionColor, TextFormatFlags.HorizontalCenter | TextFormatFlags.Top | TextFormatFlags.WordBreak | TextFormatFlags.NoPadding);
            }
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing) { _centerFont.Dispose(); _captionFont.Dispose(); }
            base.Dispose(disposing);
        }
    }

    public class StudioBadge : Control
    {
        private Color _fillColor = Color.FromArgb(29, 45, 38);
        private Color _textColor = Color.FromArgb(83, 221, 151);
        private int _cornerRadius = 8;
        // Translated badge text ("PROTÉGÉ", "انتباه", ...) is often wider than
        // the English original. The badge grows to fit its text instead of
        // letting the text spill over neighbouring controls.
        private const int MaxAutoWidth = 280;
        private Font _font = new Font("Segoe UI Semibold", 7.5f, FontStyle.Regular, GraphicsUnit.Point);

        public Color FillColor { get { return _fillColor; } set { _fillColor = value; Invalidate(); } }
        public Color TextColor { get { return _textColor; } set { _textColor = value; Invalidate(); } }
        public int CornerRadius { get { return _cornerRadius; } set { _cornerRadius = value; Invalidate(); } }

        public StudioBadge()
        {
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw | ControlStyles.UserPaint | ControlStyles.SupportsTransparentBackColor, true);
            BackColor = Color.Transparent;
            Size = new Size(90, 24);
        }

        protected override void OnTextChanged(EventArgs e)
        {
            base.OnTextChanged(e);
            FitToText();
        }

        protected override void OnFontChanged(EventArgs e)
        {
            base.OnFontChanged(e);
            FitToText();
        }

        private void FitToText()
        {
            if (IsDisposed || Disposing) return;
            if (string.IsNullOrEmpty(Text)) return;
            try
            {
                Size measured = TextRenderer.MeasureText(Text, _font, new Size(int.MaxValue, Height), TextFormatFlags.SingleLine | TextFormatFlags.NoPadding);
                int wanted = measured.Width + 18;
                if (wanted > MaxAutoWidth) wanted = MaxAutoWidth;
                if (wanted != Width && Parent != null)
                {
                    // Badges sit at a fixed left edge; growing rightwards keeps
                    // them inside their card in every language.
                    SuspendLayout();
                    Width = wanted;
                    ResumeLayout();
                }
            }
            catch { }
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            Color canvas = Parent != null ? Parent.BackColor : Color.FromArgb(18, 25, 36);
            e.Graphics.Clear(canvas);
            Rectangle rect = new Rectangle(0, 0, Width - 1, Height - 1);
            using (GraphicsPath path = Draw.RoundRect(rect, _cornerRadius))
            using (SolidBrush brush = new SolidBrush(_fillColor))
            {
                e.Graphics.FillPath(brush, path);
            }
            TextRenderer.DrawText(e.Graphics, Text, _font, rect, _textColor, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine | TextFormatFlags.NoPadding | TextFormatFlags.EndEllipsis);
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing) _font.Dispose();
            base.Dispose(disposing);
        }
    }

    public class StudioComboBox : ComboBox
    {
        private Color _selectionBackColor = Color.FromArgb(40, 52, 72);

        public Color SelectionBackColor { get { return _selectionBackColor; } set { _selectionBackColor = value; Invalidate(); } }

        public StudioComboBox()
        {
            DrawMode = DrawMode.OwnerDrawFixed;
            FlatStyle = FlatStyle.Flat;
            DropDownStyle = ComboBoxStyle.DropDownList;
            BackColor = Color.FromArgb(18, 25, 36);
            ForeColor = Color.FromArgb(228, 236, 247);
            Font = new Font("Segoe UI", 9f, FontStyle.Regular, GraphicsUnit.Point);
        }

        protected override void OnDrawItem(DrawItemEventArgs e)
        {
            if (e.Index < 0) return;
            Color background = (e.State & DrawItemState.Selected) == DrawItemState.Selected ? _selectionBackColor : BackColor;
            using (SolidBrush brush = new SolidBrush(background)) e.Graphics.FillRectangle(brush, e.Bounds);
            TextRenderer.DrawText(e.Graphics, Items[e.Index].ToString(), Font, e.Bounds, ForeColor, TextFormatFlags.Left | TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis);
        }
    }

    public class StudioSparkline : Control
    {
        private int[] _values = new int[0];
        private Color _lineColor = Color.FromArgb(108, 99, 255);
        private Color _fillColor = Color.FromArgb(35, 45, 95);

        public int[] Values { get { return _values; } set { _values = value ?? new int[0]; Invalidate(); } }
        public Color LineColor { get { return _lineColor; } set { _lineColor = value; Invalidate(); } }
        public Color FillColor { get { return _fillColor; } set { _fillColor = value; Invalidate(); } }

        public StudioSparkline()
        {
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw | ControlStyles.UserPaint | ControlStyles.SupportsTransparentBackColor, true);
            BackColor = Color.Transparent;
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            Color canvas = Parent != null ? Parent.BackColor : Color.FromArgb(18, 25, 36);
            e.Graphics.Clear(canvas);
            if (_values == null || _values.Length < 2) return;
            int max = 1;
            foreach (int value in _values) if (value > max) max = value;
            List<PointF> points = new List<PointF>();
            float step = (float)(Width - 4) / (_values.Length - 1);
            for (int i = 0; i < _values.Length; i++)
            {
                float x = 2 + step * i;
                float y = Height - 4 - ((float)_values[i] / max) * (Height - 10);
                points.Add(new PointF(x, y));
            }
            using (GraphicsPath area = new GraphicsPath())
            {
                area.AddLines(points.ToArray());
                area.AddLine(points[points.Count - 1].X, Height - 2, points[0].X, Height - 2);
                area.CloseFigure();
                using (LinearGradientBrush brush = new LinearGradientBrush(new Rectangle(0, 0, Width, Height), _fillColor, Color.FromArgb(10, _fillColor), 90f))
                {
                    e.Graphics.FillPath(brush, area);
                }
            }
            using (Pen pen = new Pen(_lineColor, 2f))
            {
                pen.StartCap = LineCap.Round; pen.EndCap = LineCap.Round;
                e.Graphics.DrawLines(pen, points.ToArray());
            }
        }
    }

    public class StudioProgress : Control
    {
        private int _value;
        private Color _trackColor = Color.FromArgb(34, 45, 61);
        private Color _fillColor = Color.FromArgb(108, 99, 255);
        private Color _fillEndColor = Color.FromArgb(51, 181, 229);

        public int Value { get { return _value; } set { _value = Math.Max(0, Math.Min(100, value)); Invalidate(); } }
        public Color TrackColor { get { return _trackColor; } set { _trackColor = value; Invalidate(); } }
        public Color FillColor { get { return _fillColor; } set { _fillColor = value; Invalidate(); } }
        public Color FillEndColor { get { return _fillEndColor; } set { _fillEndColor = value; Invalidate(); } }

        public StudioProgress()
        {
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw | ControlStyles.UserPaint, true);
            Size = new Size(200, 6);
            TabStop = false;
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            Color canvas = Parent != null ? Parent.BackColor : Color.FromArgb(8, 12, 18);
            e.Graphics.Clear(canvas);
            Rectangle track = new Rectangle(0, 0, Width - 1, Height - 1);
            int radius = Math.Max(1, track.Height / 2);
            Draw.FillRoundRect(e.Graphics, track, radius, _trackColor);
            int fillWidth = (int)Math.Round((double)track.Width * _value / 100.0);
            if (fillWidth < track.Height) fillWidth = _value > 0 ? track.Height : 0;
            if (fillWidth > track.Width) fillWidth = track.Width;
            if (fillWidth <= 0) return;
            Rectangle fill = new Rectangle(0, 0, fillWidth, track.Height);
            using (GraphicsPath path = Draw.RoundRect(fill, radius))
            using (LinearGradientBrush brush = new LinearGradientBrush(new Rectangle(0, 0, Math.Max(2, track.Width), Math.Max(2, track.Height)), _fillColor, _fillEndColor, 0f))
            {
                e.Graphics.FillPath(brush, path);
            }
        }
    }
}
